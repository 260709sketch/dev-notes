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

    func playCurrentItem(seekTo time: TimeInterval, autoPlay: Bool = true, preferOfficial: Bool = false) {
        guard let item = currentItem else { return }
        isLoading = true
        currentTime = time
        if item.duration > 0 { duration = item.duration }
        // 换曲目 / 重新解析：清除「官方通道已重试」标记，新歌可再次检测试听
        if !preferOfficial {
            officialRetriedTrackKey = nil
        }
        Task {
            do {
                let resolved = try await MusicURLResolver.shared.resolvePlayback(
                    for: item, quality: AppState.shared.audioQuality, preferOfficial: preferOfficial)
                guard let url = URL(string: resolved.url) else {
                    isLoading = false
                    return
                }
                if resolved.isFallbackSource, let name = resolved.fromCustomSource {
                    await MainActor.run { ToastCenter.shared.show("自动换源：\(name)") }
                }
                await MainActor.run {
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
        lastContinuousSeekAt = 0
    }

    /// 拖动中更新预览时间（手指移动时持续调用）。
    ///
    /// ★ 音频跟手：MPV 的 seek 命令即时返回且内部串行化，直接按节流下发即可。
    func updateScrubbing(to time: TimeInterval) {
        guard isScrubbing, time.isFinite else { return }
        scrubTime = time
        requestContinuousSeek(to: time)
    }

    // MARK: 拖动中的连续 seek

    /// 拖动过程中让**音频**跟到手指位置。
    ///
    /// mpv 的 seek 是「flush 解码/输出队列 → 重新填充 → 从新位置渲染」，
    /// 命令即时返回、内部串行。为避免 60Hz 地灌 seek 压垮 demuxer（远端无损
    /// 每次都要重拉字节范围），按 0.1s 节流下发；松手时 `endScrubbing`
    /// 再精确补一次最终位置。
    private var lastContinuousSeekAt: TimeInterval = 0

    private func requestContinuousSeek(to target: TimeInterval) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastContinuousSeekAt >= 0.1 else { return }
        lastContinuousSeekAt = now
        engine.seek(to: target)
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
        engine.seek(to: target)
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        if isScrubbing {
            scrubTime = time
            return
        }
        let target = max(0, time)
        currentTime = target
        engine.seek(to: target)
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

    /// 上次断流自动恢复的时刻（冷却防死循环）
    private var lastAutoReloadAt: TimeInterval = 0
    /// 已经尝试过「官方通道重播」的曲目 key（防试听检测无限循环）
    private var officialRetriedTrackKey: String?

    /// 曲目结束处理。
    ///
    /// ## 为什么不能见 EOF 就切歌（「拖动/听一会就自动切歌」的根因）
    ///
    /// 网易云 CDN 会在 seek 重拉连接或长时间播放后**掐断音频流**，mpv 把
    /// 「流被断开」同样报告成 END_FILE(EOF) —— 和真正播完无法从事件本身区分。
    /// AVPlayer 时代遇到断流会自动重试缓冲，mpv 则直接判死并进 idle。
    ///
    /// 判据：EOF 时**播放位置必须接近时长**（差 5 秒内）才算自然播完；
    /// 位置还早就是断流 —— 保持进度重载当前曲目（重新解析播放 URL）续播，
    /// 并用 5 秒冷却防止网络持续恶化时的无限重载循环。
    private func handleTrackEnded(_ reason: MPVEngine.TrackEndReason) {
        // 换曲触发旧文件的 END_FILE(STOP) 已在引擎层过滤

        // ① 试听片段检测：**只在「疑似自然播完」时触发**（EOF 且位置接近
        //    实际播放的 duration），且**每首歌只尝试一次**。自定义音源对
        //    VIP/无版权歌曲常返回 15~30s 试听链接，播完是真 EOF、位置接近
        //    试听自身时长，但远短于歌曲元数据时长 —— 表现即「放十几秒就
        //    重头再放」。这时跳过自定义音源走官方通道重播完整版。
        //
        //    ⚠️ 必须限制单次：若官方通道也拿不到完整版（无版权），preferOfficial
        //    重播仍可能是试听，若不设防会「试听→重播→试听→重播」无限循环。
        if reason == .eof,
           let item = currentItem,
           item.duration > 30,                    // 元数据是完整歌曲
           duration > 0,                          // 实际时长已知
           item.duration - duration > 20,         // 实际比元数据短 20s+ → 试听
           currentTime >= duration - 5,           // 确实播到了试听结尾
           officialRetriedTrackKey != item.keyOf { // 尚未尝试过官方通道
            officialRetriedTrackKey = item.keyOf
            PlayerDiag.log("试听片段检测 dur=\(String(format: "%.1f", duration)) meta=\(String(format: "%.1f", item.duration)) → 官方通道重播完整版")
            ToastCenter.shared.show("已切换为完整版播放")
            playCurrentItem(seekTo: 0, autoPlay: true, preferOfficial: true)
            return
        }

        // ② 真·自然播完（EOF 且位置接近实际时长）
        let nearEnd = duration > 0 && currentTime >= duration - 5
        if reason == .eof, nearEnd {
            next()
            return
        }

        // ③ 断流 / 播放错误：重载续播。
        // ⚠️ duration 读不到（<=0）时一律按断流处理：断流瞬间 duration 属性
        // 可能已不可用，把它误判成播完就是「放十几秒就切歌」的残留路径。
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAutoReloadAt >= 5 else {
            PlayerDiag.log("断流恢复冷却中（\(String(format: "%.1f", now - lastAutoReloadAt))s），忽略本次")
            return
        }
        lastAutoReloadAt = now
        PlayerDiag.log("播放中断 reason=\(reason) pos=\(String(format: "%.1f", currentTime))/\(String(format: "%.1f", duration)) → 重载续播")
        ToastCenter.shared.show("网络波动，已自动恢复播放")
        playCurrentItem(seekTo: currentTime, autoPlay: true)
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
        if let pos = engine.timePos {
            currentTime = pos
        }
        // 时长
        if let d = engine.duration, d.isFinite, d > 0, abs(d - duration) > 0.1 {
            duration = d
        }
        // ★ 试听片段**事前拦截**：LX 音源对 VIP/无版权歌曲返回 15~30s 试听链接，
        //   播放开始 1~2 秒内 mpv 就能报告真实 duration。一旦发现真实时长远短于
        //   歌曲元数据（短 20s+ 且未尝试过官方通道），立即换官方通道重播，
        //   而不是等播完试听才发现（用户几乎无感）。
        if !isScrubbing,
           let item = currentItem,
           item.duration > 30,
           duration > 0, duration < item.duration - 20,
           officialRetriedTrackKey != item.keyOf,
           !isLoading {
            officialRetriedTrackKey = item.keyOf
            PlayerDiag.log("试听片段事前拦截 dur=\(String(format: "%.1f", duration)) meta=\(String(format: "%.1f", item.duration)) → 官方通道重播")
            ToastCenter.shared.show("已切换完整版")
            playCurrentItem(seekTo: 0, autoPlay: true, preferOfficial: true)
            return
        }
        // 渲染态：缓冲期（paused-for-cache）音频没有在走，歌词时钟据此冻结
        let rendering = !engine.isPaused && !engine.isCoreIdle && !engine.isBuffering
        if rendering != isRenderingAudio {
            isRenderingAudio = rendering
        }
        // isPlaying 以引擎真实状态校正（例如系统打断 / 音频路由变化导致的暂停）
        let enginePlaying = !engine.isPaused && !engine.isCoreIdle
        if hasActiveTrack, !isScrubbing, enginePlaying != isPlaying {
            isPlaying = enginePlaying
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
