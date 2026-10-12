import AVFoundation
import MediaPlayer
import SwiftUI

/// 音频会话配置（后台播放 + 锁屏控制 + 无损输出的蓝牙/隔空播放策略）
enum AudioSessionManager {
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        // allowBluetoothA2DP / allowAirPlay：保证无损音频在蓝牙耳机与隔空播放下不被强制降级
        try? session.setCategory(.playback, mode: .default,
                                 options: [.allowBluetoothA2DP, .allowAirPlay])
        try? session.setActive(true)
    }

    static func activate() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

/// 播放内核（替代 react-native-track-player，基于 AVPlayer）
@MainActor
final class PlayerCore: NSObject, ObservableObject {
    static let shared = PlayerCore()

    // MARK: 对外状态

    @Published var queue: [MusicItem] = []
    @Published var currentIndex: Int? = nil
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var hasActiveTrack: Bool = false
    /// 加载中的播放地址（loading 态）
    @Published var isLoading: Bool = false

    /// 是否正在拖动进度条（拖动中歌词跟随预览时间，不回落真实播放时间）
    @Published var isScrubbing: Bool = false
    /// 拖动中的预览时间
    @Published var scrubTime: TimeInterval = 0
    /// 结束拖动的兜底任务（防止 seek 回调不返回时 isScrubbing 永久为 true）
    private var scrubTimeoutItem: DispatchWorkItem?

    /// 拖动中「连续 seek」的最新目标（`nil` = 没有待补发的目标）
    private var pendingSeekTarget: TimeInterval?
    /// 是否已有一个 seek 在飞（保证同一时刻只发一个，见 `requestContinuousSeek`）
    private var seekInFlight = false

    var currentItem: MusicItem? {
        guard let idx = currentIndex, queue.indices.contains(idx) else { return nil }
        return queue[idx]
    }

    /// 供 UI（进度条 / 歌词）渲染使用的时间：
    /// 拖动中显示 scrubTime，其余显示真实播放时间，保证拖动时歌词不跳回
    var displayTime: TimeInterval {
        isScrubbing ? scrubTime : currentTime
    }

    /// 播放器的**即时**真实位置，直接向 AVPlayer 查询（不经 `currentTime` 的轮询缓存）。
    ///
    /// 用途：歌词时钟的硬校准锚点（见 `PlayerService.precisePlaybackTime`）。
    /// `currentTime` 由周期回调更新，在无损 / Hi-Res 大文件上回调间隔会明显拉长，
    /// 松手瞬间可能滞后上百毫秒；而 `AVPlayer.currentTime()` 是同步即时值。
    /// 未加载曲目时回落到 0，避免 NaN 传进歌词页。
    ///
    /// ⚠️ **seek 落地前钉在目标位置**（见 `seekLandingTarget`）：seek 发出到音频
    /// 真正从新位置渲染出来之间有一个「缓冲空窗」，这期间任何时间源都**不允许外推**，
    /// 否则歌词会带着空窗时长一路跑在人声前面 —— 这正是「拖一次进度条就永久脱节」的根。
    var playerPosition: TimeInterval {
        if let target = seekLandingTarget { return target }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// 音频**此刻是否真的在渲染**（`AVPlayer.timeControlStatus == .playing`）。
    ///
    /// 这是「声音在流动」的权威信号：`.waitingToPlayAtSpecifiedRate` 表示
    /// 正在缓冲（seek 后的重新拉流 / 卡顿），此时**音频没有在走**，
    /// 歌词时钟必须冻结，而不是继续外推。
    @Published private(set) var isRenderingAudio: Bool = false

    /// 是否处在「seek 已发出、音频尚未从新位置渲染」的空窗期。
    /// 歌词时钟在此期间必须冻结（见 `pushClock` / `playerPosition`）。
    var isAwaitingSeekLanding: Bool { seekLandingTarget != nil }

    /// 「seek 落地监测」：seek 发出后、音频真正从新位置渲染出来之前，保存目标位置。
    /// 非 nil 期间 `playerPosition` 钉在该目标、歌词时钟禁止外推。
    private var seekLandingTarget: TimeInterval?
    /// 落地判定用的上一次采样（需要「连续两次在目标附近推进」才算真落地）。
    private var landingProbe: TimeInterval?
    /// 落地监测自身的兜底超时（防止周期观察者一直不回调时位置被永久钉死）。
    private var landingTimeoutItem: DispatchWorkItem?

    /// seek 落地（音频真的从新位置开始推进）时广播。歌词页收到后做硬校准。
    static let seekDidLandNotification = Notification.Name("PlayerCore.seekDidLand")

    /// 落地监测的兜底时长（秒）：长距离 seek（重建解码器 + 大跨度重拉）缓冲空窗
    /// 可能超过 2 秒，兜底要给足余量。正常情况下 `isRenderingAudio` 判据会在音频
    /// 一开始渲染就放行，这个超时只是「周期观察者彻底失效」时的最后安全网。
    nonisolated static let seekLandingTimeoutSeconds: Double = 8.0

    /// 逐字歌词高亮最重视刷新率，波形/卡拉OK 用分数秒驱动
    private var preferredTimescale: CMTimeScale { 600 }

    /// Seek 精度容差（秒）。
    ///
    /// Apple 文档明确指出：`toleranceBefore/After = .zero` 会**要求框架解码大量数据**以做到样本级精确，
    /// 在无损 / Hi-Res（FLAC 24bit、高采样率）文件上耗时会显著增加 —— 这会造成拖动松手后
    /// 播放位置迟迟不落地，表现为「歌词与人声不同步」。
    ///
    /// 策略：用一个**远低于人耳可感阈值、但非零**的容差。
    /// - 人耳可感知的音画不同步阈值约 20–30ms 以上；
    /// - 取 20ms，既能落到最近的解码边界（快得多），又不会被听出来；
    /// - 对逐字（卡拉OK）歌词也足够精确（单字通常 100ms 量级）。
    /// 可见性为 internal（而非 private）以便单元测试锁死该策略。
    /// 标 `nonisolated`：`@MainActor` 类的 static 存储属性默认被 actor 隔离，
    /// 测试方法（非 MainActor）读取会报错；这两个常量本就是不可变纯数据，无需隔离。
    nonisolated static let seekToleranceSeconds: Double = 0.02

    /// 结束拖动的兜底超时（秒）：seek 回调不返回时强制退出 scrubbing 态
    nonisolated static let scrubTimeoutSeconds: Double = 1.5

    private var seekTolerance: CMTime {
        CMTime(seconds: Self.seekToleranceSeconds, preferredTimescale: preferredTimescale)
    }

    // MARK: 内部

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// 记录上次拉取的播放 URL（避免同曲重复解析导致闪断）

    private override init() {
        super.init()
        setupTimeObserver()
        setupEndObserver()
        setupRemoteCommands()
        // 「音频真的在渲染」的权威信号：缓冲等待期（seek 后重新拉流、卡顿）
        // 值会变成 .waitingToPlayAtSpecifiedRate，此时音频没有在走。
        // ⚠️ 不经过 DispatchQueue.main.async：KVO 回调本身已在 main queue，
        //   再加一层异步跳板会让 updateSeekLanding 读到滞后一拍的旧值，
        //   落地判定因此多冻结一拍 —— 歌词就会滞后。
        timeControlObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            self?.isRenderingAudio = (player.timeControlStatus == .playing)
        }
    }

    private var timeControlObservation: NSKeyValueObservation?

    // MARK: 对外控制

    func play(queue newQueue: [MusicItem], startIndex: Int = 0) {
        self.queue = newQueue
        currentIndex = newQueue.isEmpty ? nil : startIndex
        if newQueue.isEmpty { return }
        playCurrentItem(seekTo: 0)
    }

    func playItem(_ item: MusicItem) {
        // 若已在当前队列里，index 定位；否则替换整队列
        if let idx = queue.firstIndex(where: { MusicItem.isSame($0, item) }) {
            currentIndex = idx
            playCurrentItem(seekTo: 0)
        } else {
            queue = [item]
            currentIndex = 0
            playCurrentItem(seekTo: 0)
        }
    }

    func playCurrentItem(seekTo time: TimeInterval, autoPlay: Bool = true) {
        guard let item = currentItem else { return }
        isLoading = true
        currentTime = time
        // 换曲目/换音源：旧 seek 的落地监测立即作废，否则新歌的 playerPosition
        // 会被旧目标钉住、歌词卡死
        abandonSeekLandingMonitor()
        Task {
            do {
                let resolved = try await MusicURLResolver.shared.resolvePlayback(
                    for: item, quality: AppState.shared.audioQuality)
                guard let url = URL(string: resolved.url) else {
                    isLoading = false
                    return
                }
                if resolved.isFallbackSource, let name = resolved.fromCustomSource {
                    await MainActor.run { ToastCenter.shared.show("自动换源：\(name)") }
                }
                await MainActor.run {
                    let avItem = Self.makePlayerItem(url: url, headers: resolved.headers)
                    observeStatus(avItem)
                    player.replaceCurrentItem(with: avItem)
                    let finish: () -> Void = { [weak self] in
                        guard let self else { return }
                        if autoPlay {
                            self.player.play()
                            self.isPlaying = true
                        } else {
                            self.isPlaying = false
                        }
                        self.isLoading = false
                    }
                    if time > 0 {
                        player.seek(to: CMTime(seconds: time, preferredTimescale: preferredTimescale),
                                   toleranceBefore: seekTolerance, toleranceAfter: seekTolerance) { _ in finish() }
                    } else {
                        finish()
                    }
                    hasActiveTrack = true
                    updateNowPlaying(item)
                    AppState.shared.recordHistory(item)
                    loadLyrics(for: item)
                }
            } catch {
                isLoading = false
            }
        }
    }

    /// 切换音源后重新解析当前歌曲（保持进度与播放/暂停状态）。
    func reloadCurrentTrack() {
        guard currentIndex != nil, currentItem != nil else { return }
        playCurrentItem(seekTo: currentTime, autoPlay: isPlaying)
    }

    /// 构造播放条目：自定义音源取链需要携带 Referer，否则部分 CDN 会拒绝请求。
    private static func makePlayerItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        guard !headers.isEmpty else { return AVPlayerItem(url: url) }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    private func observeStatus(_ avItem: AVPlayerItem) {
        statusObservation = avItem.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .readyToPlay {
                    let d = item.duration.seconds
                    if d.isFinite && d > 0 && (self?.duration ?? 0) != d {
                        self?.duration = d
                    }
                }
            }
        }
    }

    // MARK: 歌词加载（按「歌词来源」优先，命中缓存不重复拉取）

    private func loadLyrics(for item: MusicItem) {
        AppState.shared.currentLrc = []
        AppState.shared.currentWordLyric = []
        Task { @MainActor in
            guard let result = await LyricsService.shared.lyrics(for: item) else { return }
            AppState.shared.currentLrc = result.lrc
            AppState.shared.currentWordLyric = result.wordLyric ?? []
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func play() {
        guard hasActiveTrack else { return }
        AudioSessionManager.activate()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        AudioSessionManager.activate()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    /// 开始拖动（歌词/进度条跟随预览时间，播放器时间保持不动）
    func beginScrubbing(to time: TimeInterval) {
        guard time.isFinite else { return }
        isScrubbing = true
        scrubTime = time
        // 清掉上一轮残留的连续 seek 目标，免得松手瞬间补发一个陈旧位置
        pendingSeekTarget = nil
        // 上一轮的落地监测同样作废（拖动中时间由手指决定）
        abandonSeekLandingMonitor()
    }

    /// 拖动中更新预览时间（手指移动时持续调用）。
    ///
    /// ★ 这里同时驱动**音频**跟手（`requestContinuousSeek`）—— 见那个方法的说明。
    func updateScrubbing(to time: TimeInterval) {
        guard isScrubbing, time.isFinite else { return }
        scrubTime = time
        requestContinuousSeek(to: time)
    }

    // MARK: 拖动中的连续 seek（对齐 Sollin 的 `_seekContinuously`）

    /// 让**音频**在拖动过程中就跟到手指位置，而不是等松手才跳。
    ///
    /// ## 为什么必须这样（原版怎么做的）
    /// Sollin（Flutter 版）用的 just_audio 例程里有个 `_Seeker.seek` / `_seekContinuously`：
    /// 拖动时**持续**发 seek，但**同一时刻只允许一个在飞** —— 期间到达的新目标只覆盖
    /// `pending`，等上一次完成后再补发**最新**那一次（旧的直接丢掉）。
    ///
    /// 我们之前是「拖动只改显示、松手才 seek 一次」，结果是**拖动全程音频都停在原位**：
    /// 进度条已经指到 3:00，唱的还是 1:20 那句 —— 手感和听感都是脱开的，
    /// 这正是「拖动进度条和音轨对不上」的直接原因。
    ///
    /// 用「单飞去重」而不是每次拖动都发 seek：无损 / Hi-Res 一次 seek 要重新解码，
    /// 60Hz 地灌进去只会把播放器压垮（表现为拖动时爆音、抖动）。
    private func requestContinuousSeek(to target: TimeInterval) {
        pendingSeekTarget = max(0, target)
        guard !seekInFlight else { return }
        issuePendingSeek()
    }

    private func issuePendingSeek() {
        guard let target = pendingSeekTarget else { return }
        pendingSeekTarget = nil
        seekInFlight = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: preferredTimescale),
                    toleranceBefore: seekTolerance, toleranceAfter: seekTolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                // 期间手指又移动过 → 补发最新那次；否则收工
                if self.pendingSeekTarget != nil { self.issuePendingSeek() }
            }
        }
    }

    /// 结束拖动：收尾 seek 到手指落点。
    ///
    /// 关键设计（修复「拖动后歌词/人声不同步」）：
    /// 1. **乐观更新**：立刻把 `currentTime` 设为目标值，让进度条/歌词的 UI 立即对准，
    ///    不必等 AVPlayer（无损 / Hi-Res 大文件上精确 seek 可能耗时数百毫秒）。
    /// 2. **兜底超时**：AVPlayer 在缓冲态下 seek 完成回调可能长时间不返回，
    ///    若不兜底，`isScrubbing` 会永久为 true，进度条从此卡死。这里 1.5s 后强制复位。
    /// 3. **完成校正**：回调里用播放器真实位置覆盖乐观值，保证长期精确。
    /// 4. 容差用 `seekToleranceSeconds`（20ms，远低于人耳可感阈值）而非 `.zero`：
    ///    样本级精确要求框架解码大量数据，无损文件上会让位置迟迟不落地，
    ///    反而制造出「歌词与人声不同步」。
    func endScrubbing(to time: TimeInterval) {
        guard time.isFinite else { return }
        let target = max(0, time)
        scrubTime = target
        // 收尾这一次 seek 由下面统一发，先清掉连续 seek 的待补发目标
        // （否则它会和收尾 seek 抢，白跑一次）
        pendingSeekTarget = nil
        // ★ 同时作废**正在飞**的那次连续 seek：长距离拖动沿途会发多个 seek，
        //   松手瞬间很可能还有一个在飞，若不清掉，它会和收尾 seek 并发、
        //   两个 seek 互相覆盖导致 AVPlayer 状态混乱（长拖特别容易踩到）。
        seekInFlight = false

        // 1) 乐观更新：UI 立即对准目标位置
        currentTime = target

        // ★ 进入 seek 落地监测：在音频真正从 target 渲染出来之前，
        //   `playerPosition` 钉在 target、歌词时钟禁止外推。
        beginSeekLandingMonitor(target: target)

        // 2) 兜底：若 seek 回调迟迟不返回，也要退出 scrubbing 态
        scrubTimeoutItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isScrubbing else { return }
                self.isScrubbing = false
                self.abandonSeekLandingMonitor()
            }
        }
        scrubTimeoutItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrubTimeoutSeconds, execute: timeout)

        player.seek(to: CMTime(seconds: target, preferredTimescale: preferredTimescale),
                    toleranceBefore: seekTolerance, toleranceAfter: seekTolerance) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                self.scrubTimeoutItem?.cancel()
                self.scrubTimeoutItem = nil
                self.isScrubbing = false
                // ⚠️ 这里**不**再写 `currentTime = player.currentTime().seconds`：
                // 长距离 seek 时回调返回的瞬间 `currentTime()` 可能已经跳到目标位置
                // 的乐观值（音频还在缓冲），拿它当进度基准会污染歌词时钟。
                // 真实位置由落地监测（周期观察者 + isRenderingAudio）统一裁决。
                // 注意：这里**不**清 `seekLandingTarget` —— seek 回调返回只说明
                // 「定位操作完成」，第一帧音频可能还没渲染出来。落地由周期观察者判定。
            }
        }
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        if isScrubbing {
            scrubTime = time
            return
        }
        let target = max(0, time)
        // 点歌词跳转 / 锁屏进度条 / 远程控制走这里，同样需要落地监测
        beginSeekLandingMonitor(target: target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: preferredTimescale),
                    toleranceBefore: seekTolerance, toleranceAfter: seekTolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 真实位置由落地监测统一裁决，不在这里用可能滞后的 currentTime() 覆盖
            }
        }
        currentTime = target
    }

    func next() {
        guard !queue.isEmpty else { return }
        let mode = AppState.shared.playMode
        switch mode {
        case 1: // 单曲循环
            playCurrentItem(seekTo: 0)
        case 2: // 随机
            guard queue.count > 1 else { playCurrentItem(seekTo: 0); return }
            let next = queue.indices.randomElement() ?? 0
            currentIndex = next
            playCurrentItem(seekTo: 0)
        default: // 顺序（列表循环）
            if let idx = currentIndex {
                let nextIndex = idx + 1
                if nextIndex < queue.count {
                    currentIndex = nextIndex
                    playCurrentItem(seekTo: 0)
                } else {
                    currentIndex = 0
                    playCurrentItem(seekTo: 0)
                }
            }
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let mode = AppState.shared.playMode
        switch mode {
        case 2:
            guard queue.count > 1 else { playCurrentItem(seekTo: 0); return }
            currentIndex = queue.indices.randomElement() ?? 0
            playCurrentItem(seekTo: 0)
        default:
            if let idx = currentIndex {
                let prev = idx - 1
                currentIndex = prev >= 0 ? prev : queue.count - 1
                playCurrentItem(seekTo: 0)
            }
        }
    }

    // MARK: 队列操作

    func addToQueue(_ items: [MusicItem]) {
        queue.append(contentsOf: items)
    }

    func removeFromQueue(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
        if let idx = currentIndex {
            let removedBefore = offsets.filter { $0 <= idx }.count
            currentIndex = idx - removedBefore
        }
    }

    func moveInQueue(from: IndexSet, to: Int) {
        queue.move(fromOffsets: from, toOffset: to)
    }

    // MARK: seek 落地监测（「拖完进度条歌词永久脱节」的核心修复）

    /// 开始监测一次 seek 的落地。
    ///
    /// ## 机制
    ///
    /// `AVPlayer.seek()` 发出后到音频**真正从新位置渲染出来**之间有一个空窗：
    /// 远端无损要重新拉字节范围、重建解码器、再填充输出缓冲。这个空窗里
    /// **进度条/`currentTime()` 可以已经在目标位置上走**，但耳朵听到的还是
    /// 空窗前的内容（或无声）。若歌词时钟在这段时间跟着外推，它就会带上
    /// 「空窗时长」的提前量，之后**永远**跑在人声前面 —— 与实测症状完全一致：
    /// 不拖动时完全同步（无空窗），一拖动必然脱节（空窗越大越严重，无损最明显）。
    ///
    /// 落地信号用 `addPeriodicTimeObserver`：它**只在时间轴真实推进（即音频真实
    /// 渲染）时回调**。连续两次在目标附近推进 = 新位置的音频真的在放了。
    private func beginSeekLandingMonitor(target: TimeInterval) {
        seekLandingTarget = max(0, target)
        landingProbe = nil
        // 自身的兜底：观察者迟迟不确认时放弃监测，绝不让位置被永久钉死。
        landingTimeoutItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // 落地信号丢失：把位置同步回播放器真实值，避免 UI/歌词
                // 被一个永远等不到的目标钉死（表现为歌词慢好几秒）
                self.currentTime = self.player.currentTime().seconds
                self.abandonSeekLandingMonitor()
            }
        }
        landingTimeoutItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seekLandingTimeoutSeconds, execute: timeout)
    }

    /// 周期观察者里调用：判定本次 seek 是否已落地。
    ///
    /// ## 为什么用「一次推进即落地」而不是「连续两次」（第三版踩的坑）
    ///
    /// 短距离 seek 空窗极短；长距离 seek（重建解码器 + 大跨度重拉）空窗很长。
    /// 第四版之前用「连续两次在目标附近推进」判定落地，本想更稳，但
    /// `addPeriodicTimeObserver` 的 0.05s 回调在**无损 / Hi-Res 大文件上会被明显拉长**
    /// —— 两次回调之间的真实间隔可能上百毫秒甚至更久。于是「连续两次推进」要等很久，
    /// 歌词时钟被冻结到那时才放行，人声已经往前走了一两秒 → 歌词**滞后**。
    ///
    /// 现在的判据：
    /// 1. `isRenderingAudio == false` → 音频还没在放，继续冻结（无论等多久）；
    /// 2. 一旦音频在渲染、且观察到时间在目标附近（允许就近落点 ±1.5s），
    ///    **第一次**就宣告落地 —— 不再要求第二次。
    ///    因为 `isRenderingAudio` 已经是「音频真的在渲染」的权威闸门，
    ///    它一成立，第一时间硬锚就能把冻结误差压到单次回调间隔（几十 ms 内）。
    private func updateSeekLanding(observerTime: TimeInterval) {
        guard let target = seekLandingTarget else { return }
        // 音频还没真正渲染（仍在 seek 后的缓冲等待期）：无条件继续等。
        if !isRenderingAudio {
            landingProbe = nil
            return
        }
        // 时间轴已在目标附近推进（允许 seek 容差造成的就近落点 ±1.5s）：
        // 音频真的从新位置放出来了，第一次观察到就落地。
        guard observerTime >= target - 1.5, observerTime <= target + 2.5 else {
            // 还在旧位置（向后拖会先观察到旧位置）：继续等
            return
        }
        abandonSeekLandingMonitor()
        NotificationCenter.default.post(
            name: Self.seekDidLandNotification, object: nil,
            userInfo: ["time": observerTime]
        )
    }

    /// 兜底：放弃监测（seek 回调迟迟不返回 / 落地信号丢失时）。
    private func abandonSeekLandingMonitor() {
        landingTimeoutItem?.cancel()
        landingTimeoutItem = nil
        seekLandingTarget = nil
        landingProbe = nil
    }
    // MARK: 观察者

    private func setupTimeObserver() {
        // 0.05s 粒度采样：逐字（卡拉OK）歌词高亮需要足够细的时间来源才能跟手。
        // 注意：这个回调**只在音频真实渲染时触发** —— 它同时充当 seek 落地探测器。
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, time.seconds.isFinite else { return }
            self.currentTime = time.seconds
            self.updateSeekLanding(observerTime: time.seconds)
        }
    }

    private func setupEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.next()
            }
        }
    }

    // MARK: NowPlaying + 远程控制

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous(); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let ev = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: ev.positionTime)
            return .success
        }
    }

    private func updateNowPlaying(_ item: MusicItem? = nil) {
        let song = item ?? currentItem
        guard let song else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "未知艺术家",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let cover = song.albumCoverURL, let url = URL(string: cover) {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                } else {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}