import AVFoundation
import MediaPlayer
import SwiftUI

/// 音频会话配置（后台播放 + 锁屏控制）。
///
/// ⚠️ 2026-10-14 修「控制中心不显示正在播放的歌曲」：`.playback` **不传任何
/// category options**。旧代码带过 `.allowBluetoothA2DP` + `.allowAirPlay`：
///   * `allowAirPlay`：Apple 文档明确「只能显式用于 PlayAndRecord 类别」，
///     对 playback 系统本就隐式开启；显式传入在部分 iOS 版本上直接让
///     `setCategory` 抛错；
///   * `allowBluetoothA2DP`：文档明确 ambient/soloAmbient/playback 三类
///     **自动**路由 A2DP，该选项只为 playAndRecord 准备。
/// 抛出的错误被 `try?` 吞掉后，类别停留在默认 `.soloAmbient` —— 歌照样能放
/// （铃声开关开着时），但系统不认「正在播放媒体」，控制中心 / 锁屏 / 灵动岛
/// 什么都没有。这正是用户反馈的症状。
enum AudioSessionManager {
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
        } catch {
            PlayerDiag.log("音频会话类别设置失败：\(error.localizedDescription)")
        }
        do {
            try session.setActive(true)
        } catch {
            PlayerDiag.log("音频会话激活失败：\(error.localizedDescription)")
        }
    }

    /// 激活会话（每次起播前调用）。
    ///
    /// 顺手自愈：类别若被其他组件（如 MPV 音频输出初始化）改跑，拉回 `.playback`，
    /// 避免「某次之后控制中心突然不显示」的幽灵问题。
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            let previous = session.category
            do {
                try session.setCategory(.playback, mode: .default)
                PlayerDiag.log("音频会话类别自 \(previous.rawValue) 拉回 playback")
            } catch {
                PlayerDiag.log("音频会话类别修复失败：\(error.localizedDescription)")
            }
        }
        do {
            try session.setActive(true)
        } catch {
            PlayerDiag.log("音频会话激活失败：\(error.localizedDescription)")
        }
    }
}

/// 播放内核（MPV / libmpv，MPVKit 预编译二进制）。
///
/// ## 为什么从 AVPlayer 换到 MPV（2026-10-12 定案）
///
/// 歌词同步问题的最终定位：歌词时钟与 `AVPlayer.currentTime()` 完全一致
/// （端到端 Δ ≈ −3ms，见 `LyricSyncProbe`），但**耳朵听到的人声与
/// `currentTime()` 差几秒** —— AVPlayer 的位置报告在 seek 后与实际渲染的
/// 音频脱节，属内核级行为，应用层无解。
///
/// MPV 的 `time-pos` 由音频输出时钟驱动，耳朵听到哪它就报哪；seek 是
/// 「flush 队列 → 重新填充 → 从新位置渲染」，期间 time-pos 不动、恢复后精确。
/// 因此歌词时钟直接读 `time-pos` 即可与可闻音频对齐，不再需要 AVPlayer 时代
/// 的「seek 落地监测 / 时钟冻结 / 硬锚」那一整套补丁（已全部移除）。
///
/// ## 结构
///
/// * `MPVEngine`：libmpv 桥接（加载/暂停/seek/EOF）；
/// * 0.05s tick：直读 `time-pos`/`duration`/缓冲态（C 调用，极便宜），
///   驱动 `currentTime` 与 `isRenderingAudio`；
/// * 队列/播放模式/锁屏命令/NowPlaying 与内核无关，逻辑不变。
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

    /// 音频此刻是否真的在渲染。
    ///
    /// MPV 语义：`!pause && !core-idle && !paused-for-cache`。
    /// seek 后的重新缓冲期 `paused-for-cache` 会变 true，此时音频没有在走，
    /// 歌词时钟据此冻结；恢复渲染后立即放行 —— 与可闻音频天然对齐。
    @Published private(set) var isRenderingAudio: Bool = false

    /// 「seek 落地监测」是 AVPlayer 时代的机制，MPV 下不需要
    /// （time-pos 本身就是渲染真值）。保留属性供旧引用编译。
    var isAwaitingSeekLanding: Bool { false }

    /// AVPlayer 时代落地监测的广播。MPV 下不再触发（time-pos 即渲染真值，
    /// 歌词时钟经 10Hz pushClock 自然跟上）。保留常量供旧订阅点编译。
    static let seekDidLandNotification = Notification.Name("PlayerCore.seekDidLand")

    /// MPV 引擎
    private let engine = MPVEngine()

    var currentItem: MusicItem? {
        guard let idx = currentIndex, queue.indices.contains(idx) else { return nil }
        return queue[idx]
    }

    /// 供 UI（进度条 / 歌词）渲染使用的时间：
    /// 拖动中显示 scrubTime，其余显示真实播放时间，保证拖动时歌词不跳回
    var displayTime: TimeInterval {
        isScrubbing ? scrubTime : currentTime
    }

    /// 播放器的**即时**真实位置 = MPV `time-pos`（音频输出时钟驱动的渲染真值）。
    /// 未加载曲目时回落到 0，避免 NaN 传进歌词页。
    var playerPosition: TimeInterval {
        engine.timePos ?? max(0, currentTime)
    }

    // MARK: 保留的内核无关常量（单元测试锁死；MPV 下部分不再参与逻辑）

    /// Seek 精度容差（秒）。AVPlayer 时代用于 `CMTime` 容差；MPV 的 keyframe seek
    /// 在音频流上精度约为一帧（几十 ms），无需此参数。保留常量供测试。
    nonisolated static let seekToleranceSeconds: Double = 0.02

    /// 拖动结束的兜底超时（秒）。AVPlayer 时代用于 seek 回调不返回的兜底；
    /// MPV 的 seek 命令即时返回，无需兜底。保留常量供测试。
    nonisolated static let scrubTimeoutSeconds: Double = 1.5

    /// 落地监测兜底超时（秒）。AVPlayer 时代机制；MPV 下无落地监测。保留供测试。
    nonisolated static let seekLandingTimeoutSeconds: Double = 8.0

    private override init() {
        super.init()
        AudioSessionManager.configure()
        engine.start()
        engine.onTrackEnded = { [weak self] reason in
            Task { @MainActor in self?.handleTrackEnded(reason) }
        }
        // 音量：读持久化值（含旧默认迁移，见 restoredVolume）
        applyVolume(Self.restoredVolume())
        setupTick()
        setupRemoteCommands()
        setupAudioSessionObservers()
    }

    // MARK: 音频会话事件（打断结束 / 媒体服务重置）

    /// 系统事件（来电、闹钟、媒体服务重置）后重新激活音频会话并补写 NowPlaying。
    ///
    /// 不自动恢复播放（是否续播由用户决定），只保证「控制中心 / 锁屏链路就绪」——
    /// 打断结束后系统会把会话挂起，若不重新激活，控制中心里我们的播放卡片会消失。
    private func setupAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruptionEnded(note) }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        }
    }

    private func handleInterruptionEnded(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .ended else { return }
        PlayerDiag.log("音频会话打断结束 → 重新激活并补写 NowPlaying")
        AudioSessionManager.activate()
        updateNowPlaying()
    }

    private func handleMediaServicesReset() {
        PlayerDiag.log("媒体服务被重置 → 重新配置音频会话并补写 NowPlaying")
        AudioSessionManager.configure()
        updateNowPlaying()
    }

    /// 读取持久化音量。
    ///
    /// ⚠️ 迁移逻辑：AVPlayer 时代音量条**从未实际生效**（AVPlayer 无软件音量，
    /// 旧 didSet 只写 UserDefaults），UserDefaults 里的 0.7 只是默认值被写回，
    /// 并不是用户意图。MPV 的 `volume` 是**软件音量** —— 会真实衰减 PCM 信号，
    /// 默认 70% 等于让响度凭空小 30%、还多做一次浮点乘法。所以把旧默认迁移为
    /// 100%，响度完全交给系统音量键（硬件/系统混音）。
    static func restoredVolume() -> Float {
        let d = UserDefaults.standard
        guard d.object(forKey: "player.volume") != nil else { return 1.0 }
        let v = d.float(forKey: "player.volume")
        if abs(v - 0.7) < 0.001 {
            d.set(Float(1.0), forKey: "player.volume")
            return 1.0
        }
        return v
    }

    deinit {
        engine.shutdown()
    }

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

    func playCurrentItem(seekTo time: TimeInterval, autoPlay: Bool = true, isReload: Bool = false) {
        guard let item = currentItem else { return }
        isLoading = true
        currentTime = time
        if item.duration > 0 { duration = item.duration }
        Task {
            do {
                // ★ 优先用预加载结果：播放到 5s 时后台已解析好下一首地址，
                //   这里命中即用，跳过网络解析等待 —— 显著提升「下一首」响应速度。
                let resolved: ResolvedPlayback
                if !isReload, let preloaded = takePreloadedPlayback(for: item) {
                    PlayerDiag.log("命中预加载地址：\(item.title)")
                    resolved = preloaded
                } else {
                    resolved = try await MusicURLResolver.shared.resolvePlayback(
                        for: item, quality: AppState.shared.audioQuality)
                }
                guard let url = URL(string: resolved.url) else {
                    isLoading = false
                    return
                }
                if resolved.isFallbackSource, let name = resolved.fromCustomSource {
                    await MainActor.run { ToastCenter.shared.show("自动换源：\(name)") }
                }
                await MainActor.run {
                    // 唤醒音频会话：App 启动时 setActive 可能失败（系统繁忙/被其他
                    // App 占用），或会话在后台被抢走后被系统 deactivate —— 每次
                    // 开始播放前主动激活一次，保证后台播放 / 控件中心 / 锁屏链路完整。
                    AudioSessionManager.activate()
                    engine.load(url: resolved.url,
                                headers: resolved.headers,
                                startAt: time,
                                autoPlay: autoPlay)
                    isPlaying = autoPlay
                    isLoading = false
                    hasActiveTrack = true
                    updateNowPlaying(item)
                    AppState.shared.recordHistory(item)
                    loadLyrics(for: item)
                }
            } catch {
                isLoading = false
                // 解析失败（LX 源偶发限流）：明确提示。
                // ⚠️ 绝不在此处自动 next() —— 换歌必须由用户或「自然播完」触发。
                PlayerDiag.log("解析播放地址失败：\(error.localizedDescription)")
                await MainActor.run {
                    ToastCenter.shared.show("播放地址解析失败，请稍后重试")
                }
            }
        }
    }

    /// 切换音源后重新解析当前歌曲（保持进度与播放/暂停状态）。
    func reloadCurrentTrack() {
        guard currentIndex != nil, currentItem != nil else { return }
        playCurrentItem(seekTo: currentTime, autoPlay: isPlaying)
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
        engine.setPaused(false)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        engine.setPaused(true)
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        AudioSessionManager.activate()
        engine.setPaused(false)
        isPlaying = true
        updateNowPlaying()
    }

    /// 开始拖动（歌词/进度条跟随预览时间，播放器时间保持不动）
    func beginScrubbing(to time: TimeInterval) {
        guard time.isFinite else { return }
        isScrubbing = true
        scrubTime = time
    }

    /// 拖动中更新预览时间（手指移动时持续调用）。
    ///
    /// ⚠️ 只改显示、**不连续 seek 音频**：音频是远端流媒体（LX 音源 CDN），
    /// 每次 seek 都是一次 Range 请求 + 解码器 flush，拖动中高频 seek 会让
    /// 音频反复中断 —— 表现就是「拖一下暂停一下再播放」。松手时才 seek 一次
    /// 到最终落点（见 `endScrubbing`）。
    func updateScrubbing(to time: TimeInterval) {
        guard isScrubbing, time.isFinite else { return }
        scrubTime = time
    }

    /// 结束拖动：精确 seek 到手指落点。
    ///
    /// MPV 下没有「回调迟迟不返回」的问题（命令即时返回、time-pos 在缓冲期
    /// 自然冻结），所以乐观更新 + 立即退出 scrubbing 态即可；歌词时钟读
    /// `time-pos`，缓冲期自动冻结、恢复后精确，不需要任何额外校准。
    func endScrubbing(to time: TimeInterval) {
        guard time.isFinite else { return }
        let target = max(0, time)
        scrubTime = target
        currentTime = target
        isScrubbing = false
        markUserSeek()
        engine.seek(to: target)
        // 锁屏 / 控制中心的进度与拖动结果保持一致
        updateNowPlaying()
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        if isScrubbing {
            scrubTime = time
            return
        }
        let target = max(0, time)
        currentTime = target
        markUserSeek()
        engine.seek(to: target)
        // 锁屏拖动进度条（changePlaybackPosition 命令）后同步 elapsed
        updateNowPlaying()
    }

    /// 最近一次**用户主动 seek**（拖进度条 / 点歌词 / 锁屏拖动）的时间戳。
    ///
    /// ★ 拖动后 CDN 必然要按新位置重发 Range 请求，第三方/官方 CDN 都可能
    ///   掐断连接 —— mpv 把「流被掐断」报告成 END_FILE(EOF)。这段窗口期内
    ///   的 EOF 是**预期内的噪音**，绝不能被解读成「播完 / 试听」触发
    ///   next() 或官方重播（「一拖动就自动切歌」的根源）。8 秒后恢复正常判定。
    private var lastUserSeekAt: CFAbsoluteTime = 0
    private let seekNoiseWindow: CFAbsoluteTime = 8
    private var isWithinSeekNoiseWindow: Bool {
        CFAbsoluteTimeGetCurrent() - lastUserSeekAt < seekNoiseWindow
    }
    private func markUserSeek() {
        lastUserSeekAt = CFAbsoluteTimeGetCurrent()
    }

    /// 音量（0~1），来自 PlayerService 的桥接
    func applyVolume(_ volume: Float) {
        engine.setVolume(percent: Double(volume) * 100)
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

    // MARK: 0.05s tick（位置 / 时长 / 渲染态）

    private var tickTimer: Timer?

    /// 上一 tick 的渲染态（检测「刚开始渲染」的上升沿，见 tick()）
    private var wasRenderingAudio = false

    /// 上次断流自动恢复的时刻（冷却防死循环）
    private var lastAutoReloadAt: TimeInterval = 0

    /// 已为哪首歌补过 NowPlaying 封面图（每首歌只异步拉一次，暂停/恢复不重复下载）
    private var nowPlayingArtworkKey: String?
    /// 已下载的封面（同歌多次更新 nowPlayingInfo 时复用，避免整块信息被无图覆盖）
    private var nowPlayingArtwork: MPMediaItemArtwork?
    /// 是否已成功向系统写入过 NowPlaying 信息（用于 tick 兜底补写）
    private var hasPublishedNowPlaying = false

    /// 曲目结束处理。
    ///
    /// ## 设计原则（2026-10-13 重构）
    ///
    /// **所有播放一律走 LX 音源解析**（`MusicURLResolver`），LX 音源不存在
    /// 「试听片段」概念，之前那套「试听检测 → 官方通道重播」的三层防护已全部移除。
    /// 现在只保留两条与音源无关的物理防护：
    ///
    /// 1. **seek 噪音窗口**：用户 seek 后 8s 内 CDN 常会掐断连接，mpv 把「流被
    ///    掐断」报告成 END_FILE(EOF)。这段窗口内的 EOF 一律按断流重载续播，
    ///    绝不切歌 —— 这是「一拖动就自动切歌」的总开关。
    /// 2. **断流重载冷却**：5s 冷却防止 CDN 持续掐断时的重载风暴。
    ///
    /// 判据：EOF 且播放位置接近实际时长 → 自然播完 → 下一首；
    /// 位置还早 → 断流 → 按 5s 冷却重载续播。
    private func handleTrackEnded(_ reason: MPVEngine.TrackEndReason) {
        // 换曲触发旧文件的 END_FILE(STOP) 已在引擎层过滤

        // ① 拖动 seek 噪音窗口：用户 seek 后 8s 内的 END_FILE（EOF/error）
        //    全部视为「CDN 掐断」的预期噪音 —— **一律重载续播**，不切歌。
        //    （重载保留 5s 冷却，避免 CDN 持续掐断时的重载风暴。）
        if reason != .stop, isWithinSeekNoiseWindow {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastAutoReloadAt >= 5 else {
                PlayerDiag.log("seek 噪音窗口 + 重载冷却中，忽略本次 END_FILE")
                return
            }
            lastAutoReloadAt = now
            PlayerDiag.log("seek 后流被掐断（\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - lastUserSeekAt))s 内）→ 静默重载续播 pos=\(String(format: "%.1f", currentTime))")
            playCurrentItem(seekTo: currentTime, autoPlay: true, isReload: true)
            return
        }

        // ② 自然播完：EOF 且位置接近实际时长。
        //    ⚠️ duration 读不到（<=0）时不能算播完 —— 断流瞬间 duration 属性
        //    可能已不可用，误判成播完就是「无声切下一首」的残留路径。
        let nearEnd = duration > 0 && currentTime >= duration - 5
        if reason == .eof, nearEnd {
            PlayerDiag.log("自然播完 pos=\(String(format: "%.1f", currentTime)) dur=\(String(format: "%.1f", duration)) → 下一首")
            next()
            return
        }

        // ③ 断流 / 播放错误：重载续播（5s 冷却防风暴）。
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAutoReloadAt >= 5 else {
            PlayerDiag.log("断流恢复冷却中（\(String(format: "%.1f", now - lastAutoReloadAt))s），忽略本次")
            return
        }
        lastAutoReloadAt = now
        PlayerDiag.log("播放中断 reason=\(reason) pos=\(String(format: "%.1f", currentTime))/\(String(format: "%.1f", duration)) → 重载续播")
        ToastCenter.shared.show("网络波动，已自动恢复播放")
        playCurrentItem(seekTo: currentTime, autoPlay: true, isReload: true)
    }

    private func setupTick() {
        let t = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func tick() {
        // 位置：time-pos 是音频输出时钟驱动的渲染真值
        // ⚠️ 去重赋值：暂停/空闲时 time-pos 恒定，若照旧无脑赋值，@Published 会
        //    每秒丢 20 次 objectWillChange —— 所有订阅方（迷你播放器进度线等）
        //    被持续拽着重算，滚动掉帧。只在真正变化时广播。
        if let pos = engine.timePos, pos != currentTime {
            currentTime = pos
        }
        // 时长
        if let d = engine.duration, d.isFinite, d > 0, abs(d - duration) > 0.1 {
            duration = d
        }
        // 渲染态：缓冲期（paused-for-cache）音频没有在走，歌词时钟据此冻结
        let rendering = !engine.isPaused && !engine.isCoreIdle && !engine.isBuffering
        if rendering != isRenderingAudio {
            isRenderingAudio = rendering
        }
        // ★ 音频真正开始渲染的那一刻（上升沿）重新激活会话并补写 NowPlaying：
        //   mpv 的音频输出链路可能在 updateNowPlaying 之后才异步初始化（甚至
        //   重置会话类别），而「有声音可闻」才是控制中心认账的时刻 —— 在这里
        //   补一刀，保证链路一定挂着我们的播放信息。
        if rendering, !wasRenderingAudio {
            AudioSessionManager.activate()
            updateNowPlaying()
        }
        wasRenderingAudio = rendering
        // isPlaying 以引擎真实状态校正（例如系统打断 / 音频路由变化导致的暂停）
        let enginePlaying = !engine.isPaused && !engine.isCoreIdle
        if hasActiveTrack, !isScrubbing, enginePlaying != isPlaying {
            isPlaying = enginePlaying
            // 播放/暂停态变化 → 同步锁屏 / 控制中心（rate 与状态保持一致）
            updateNowPlaying()
        }
        // ★ 控制中心 / 锁屏 / 灵动岛兜底同步：一旦有活跃曲目而系统侧还没有
        //   NowPlaying 信息（`hasPublishedNowPlaying == false` 表示从未写过），
        //   每 tick 补写一次，直到成功。防止「启动后第一次播放」时
        //   updateNowPlaying 因任何原因被跳过导致控制中心空着。
        if hasActiveTrack, !hasPublishedNowPlaying {
            updateNowPlaying()
        }
        // ★ 预加载下一首：播放到 5 秒时，后台把下一首的播放地址解析好并缓存，
        //   用户点「下一首」时可以直接用缓存地址起播，消除解析等待（响应更跟手）。
        if hasActiveTrack, !isLoading, !isScrubbing,
           currentTime >= 5, preloadedTrackKey != nextTrack?.keyOf {
            preloadNext()
        }
    }

    // MARK: 预加载下一首

    /// 已预加载的曲目 key（避免对同一首重复解析）
    private var preloadedTrackKey: String?
    /// 预加载到的地址缓存：[曲目 key: ResolvedPlayback]
    private var preloadedPlayback: [String: ResolvedPlayback] = [:]

    /// 当前队列里的「下一首」（与 `next()` 的顺序模式逻辑保持一致）。
    private var nextTrack: MusicItem? {
        guard !queue.isEmpty, let idx = currentIndex else { return nil }
        switch AppState.shared.playMode {
        case 1: return currentItem                       // 单曲循环：就是自己
        case 2: return queue.count > 1
            ? queue.indices.filter { $0 != idx }.randomElement().map { queue[$0] }
            : currentItem
        default:
            let nextIndex = (idx + 1) % queue.count
            return queue[nextIndex]
        }
    }

    /// 提前解析下一首的播放地址并缓存（播放到 5s 时触发）。
    private func preloadNext() {
        guard let target = nextTrack else { return }
        let key = target.keyOf
        guard preloadedTrackKey != key else { return }
        preloadedTrackKey = key
        // 已完成预加载的（含本次）不再重复
        if preloadedPlayback[key] != nil { return }
        Task { [weak self] in
            let quality = AppState.shared.audioQuality
            guard let resolved = try? await MusicURLResolver.shared.resolvePlayback(
                for: target, quality: quality) else { return }
            await MainActor.run {
                guard let self else { return }
                // 只保留最近两首，避免字典无限膨胀
                if self.preloadedPlayback.count > 2 { self.preloadedPlayback.removeAll() }
                self.preloadedPlayback[key] = resolved
                PlayerDiag.log("已预加载下一首：\(target.title)")
            }
        }
    }

    /// 取预加载地址（命中则清缓存并返回）。
    func takePreloadedPlayback(for item: MusicItem) -> ResolvedPlayback? {
        preloadedPlayback.removeValue(forKey: item.keyOf)
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

        let center = MPNowPlayingInfoCenter.default()
        let isNewSong = nowPlayingArtworkKey != song.keyOf
        if isNewSong {
            nowPlayingArtworkKey = song.keyOf
            nowPlayingArtwork = nil     // 换歌即作废上一首封面，防止错配
        }
        // ★ 标记「已经成功写过一条 NowPlaying」——不能用 nowPlayingArtworkKey 判断
        //   （它在封面下载前就被赋值，无法区分「已写过基础信息」与「只登记了 key」）。
        hasPublishedNowPlaying = true

        // ① 立即写入基础信息（**不等封面**）：
        //    控制中心 / 锁屏 / 灵动岛在上报的同一刻就能拿到标题、时长与播放态。
        //    旧实现是「封面图下载完成后才写 nowPlayingInfo」——封面请求慢/挂起时
        //    系统侧长时间没有任何 NowPlaying 信息，表现即「什么都不显示」。
        var info = nowPlayingInfo(for: song)
        if !isNewSong, let artwork = nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork    // 同歌更新：带上已下载的封面
        }
        center.nowPlayingInfo = info
        // ② 播放状态显式声明（playing / paused / stopped）：
        //    系统据此展示与控制卡片（含灵动岛的媒体活动）。
        if hasActiveTrack {
            center.playbackState = isPlaying ? .playing : .paused
        } else {
            center.playbackState = .stopped
        }
        PlayerDiag.log("NowPlaying 更新 title=\(song.title) playing=\(isPlaying) dur=\(String(format: "%.1f", duration)) state=\(center.playbackState.rawValue) cat=\(AVAudioSession.sharedInstance().category.rawValue)")

        // ③ 封面图：每首歌只异步拉一次（走 WellImageCache 的缩图缓存，与列表/播放页
        //    共用同一份解码结果），到图后补写同一条信息；失败则保持无封面，不影响显示。
        guard isNewSong, let coverURL = WellArtworkURL.resolved(song.albumCoverURL, pixelSize: 1024) else { return }
        Task { [weak self] in
            guard let image = await WellImageCache.shared.image(for: coverURL) else { return }
            guard let self, let current = self.currentItem, MusicItem.isSame(current, song) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.nowPlayingArtwork = artwork
            var latest = self.nowPlayingInfo(for: song)
            latest[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = latest
            PlayerDiag.log("NowPlaying 封面已补齐：\(song.title)")
        }
    }

    /// NowPlaying 基础信息（标题 / 艺人 / 专辑 / 时长 / 进度 / 速率）。
    /// `MPNowPlayingInfoPropertyDefaultPlaybackRate` 恒为 1.0：系统在控制中心
    /// 按「播放」键时按这个速率恢复播放，与当前是否在播无关。
    ///
    /// ⚠️ `MPNowPlayingInfoPropertyMediaType = .audio`：显式声明媒体类型。
    /// 不声明时，部分 iOS 版本在锁屏/灵动岛上会把媒体卡片按「未知类型」处理
    /// 甚至不展示 —— 这是「控制中心显示未在播放」的一个常见成因。
    private func nowPlayingInfo(for song: MusicItem) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "未知艺术家",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: max(duration, 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(currentTime, 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if duration > 0 {
            info[MPNowPlayingInfoPropertyPlaybackProgress] = max(currentTime, 0) / duration
        }
        return info
    }
}
