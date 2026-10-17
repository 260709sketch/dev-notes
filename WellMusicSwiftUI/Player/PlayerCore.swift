import AVFoundation
import MediaPlayer
import SwiftUI

/// 音频会话配置（后台播放 + 锁屏 / 控制中心）。
///
/// ## 历史坑一：非法的 category options（已修）
///
/// 旧代码在 `.playback` 上带过 `.allowBluetoothA2DP` + `.allowAirPlay`：
/// `allowAirPlay` 文档明确「只能显式用于 PlayAndRecord」，`allowBluetoothA2DP`
/// 文档明确 ambient/soloAmbient/playback 三类**自动**路由 A2DP —— 显式传入在
/// 部分 iOS 版本上直接让 `setCategory` 抛错；错误被 `try?` 吞掉后类别停留在
/// 默认 `.soloAmbient`，歌能放但系统不认「正在播放媒体」。
///
/// ## ★★ 历史坑二（2026-10-14 定位，本轮根因）：mpv 把会话改成「可混音」★★
///
/// 修掉坑一之后控制中心**仍然**不显示。真正的原因不在我们这边 ——
/// mpv 的 audiounit 音频输出（`audio/out/ao_audiounit.m`）会在 AO 初始化时
/// **自己改写会话**：
///
/// ```objc
/// AVAudioSessionCategoryOptions options = 0;
/// if (!(ao->init_flags & AO_INIT_EXCLUSIVE))
///     options |= AVAudioSessionCategoryOptionMixWithOthers;   // ← 默认带混音
/// [instance setCategory:AVAudioSessionCategoryPlayback withOptions:options error:nil];
/// [instance setMode:AVAudioSessionModeMoviePlayback error:nil];
/// [instance setActive:YES error:nil];
/// ```
///
/// 三重要命之处：
/// 1. AO 是在 `engine.load()` 时才创建的 → 这句**晚于**我们起播前的 `activate()`，
///    我们设的配置被它整块覆盖；
/// 2. 覆盖后类别**仍然是 `.playback`**，所以旧巡检 `category != .playback`
///    恒为假 —— 自愈永远不会触发，问题看起来「查不出原因」；
/// 3. 覆盖后会话带上了 `.mixWithOthers`。**iOS 只把非混音的音频会话认作
///    Now Playing 应用**，可混音的 App 被当成「背景音源」→ 控制中心 / 锁屏 /
///    灵动岛一概不出卡片（歌照样正常播放）。
///
/// 两条修复一起上：
/// * 根因侧：mpv 加 `audio-exclusive=yes`（见 `MPVEngine.start()`），它会置位
///   `AO_INIT_EXCLUSIVE`，mpv 自己就以 `options: 0` 设置会话；
/// * 应用侧：本类型的判据从「类别」扩展为「**类别 + 混音选项**」，并统一用
///   `.playback + .default + .longFormAudio + options: []`
///   重写会话 —— 即使 mpv 之后因格式变化重建 AO 又改跑会话，巡检也能在 5s 内拉回。
enum AudioSessionManager {
    /// 目标会话参数。
    ///
    /// * `mode: .default` —— 纯音乐播放（mpv 会把它改成 `.moviePlayback`，
    ///   那是给视频用的；我们重写时按音乐类 App 的正确取值拉回）；
    /// * `policy: .longFormAudio` —— 音乐 / 有声书这类「长时间播放」的路由策略，
    ///   与音乐类 App 的既定行为一致（见
    ///   `applyAudioMixPreference`）；
    /// * `options: []` —— **绝不可带 `.mixWithOthers`**，见上文坑二。
    static let targetMode: AVAudioSession.Mode = .default
    static let targetPolicy: AVAudioSession.RouteSharingPolicy = .longFormAudio

    /// 把会话写成目标形态（会抛错，由调用方决定怎么记录）。
    static func apply(to session: AVAudioSession) throws {
        try session.setCategory(.playback, mode: targetMode, policy: targetPolicy, options: [])
    }

    /// 当前会话是否**偏离**目标形态。
    ///
    /// ⚠️ 判据必须包含 `categoryOptions.contains(.mixWithOthers)`：
    /// 只判类别的话，「类别是 playback、但被 mpv 加上了混音」这种最要命的情形
    /// 会被判为「正常」—— 这正是坑二能长期潜伏的原因。
    static var needsRepair: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.category != .playback
            || session.categoryOptions.contains(.mixWithOthers)
    }

    /// 诊断串：类别 + 选项 + 模式（日志里一眼看出是不是混音态）。
    static var stateDescription: String {
        let session = AVAudioSession.sharedInstance()
        let mixing = session.categoryOptions.contains(.mixWithOthers) ? "混音(致命)" : "非混音"
        return "cat=\(session.category.rawValue) \(mixing) opts=\(session.categoryOptions.rawValue) mode=\(session.mode.rawValue)"
    }

    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try apply(to: session)
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
    /// 顺手自愈：会话若被其他组件（MPV 音频输出初始化——见坑二）改跑，
    /// 拉回目标形态，避免「某次之后控制中心突然不显示」的幽灵问题。
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        if needsRepair {
            let before = stateDescription
            do {
                try apply(to: session)
                PlayerDiag.log("音频会话已拉回目标形态：\(before) → \(stateDescription)")
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

    @Published var queue: [MusicItem] = [] {
        didSet { queueRevision &+= 1 }
    }

    /// 队列版本号：`queue` 每次被写入就 +1。
    ///
    /// 用途（2026-10-14 16:18 掉帧排查）：`PlayerService.syncFromCore()` 在 **10Hz** 轮询里
    /// 原本**无条件**把整个队列搬成 `[Track]` 再深比较一遍 —— `Track.from` 每首都要算
    /// 三次 `keyOf` 的字符串哈希（还含两次字符串插值），队列 1000 首时单次就是数毫秒，
    /// 而且是每秒 10 次的固定开销，主线程被反复占块 → 「每个页面上下滑动都掉帧」。
    /// 有版本号之后，轮询只要比对一次 Int（O(1)），队列真的变了才重建。
    private(set) var queueRevision: Int = 0


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
        // 老 API 补充注册（现代 iOS 下为幂等空操作）：部分版本对非 AVPlayer 内核
        // 的后台遥控注册更保守，留着无害（2026-10-14 「控制中心不显示」加固项）。
        _ = UIApplication.shared.beginReceivingRemoteControlEvents()
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
        // 普通播放 = 退出漫游会话（★ 2026-10-16）
        isFMMode = false
        self.queue = newQueue
        currentIndex = newQueue.isEmpty ? nil : startIndex
        if newQueue.isEmpty { return }
        playCurrentItem(seekTo: 0)
    }

    // MARK: - 私人漫游会话（★ 2026-10-16 对齐 Kumone 机制）
    //
    // Kumone 的私人漫游是「流式」的：队列里剩的歌将尽时自动再拉一批，
    // 漫游可以无限续下去；普通播放/换来源时退出该模式。
    // 我们此前的实现只拉 3 批（9 首）播完就停 —— 这里补上自动补货。

    private(set) var isFMMode = false
    private var fmRefilling = false

    /// 进入漫游会话（由「私人漫游」入口在起播后调用）
    func beginFMSession() {
        isFMMode = true
        refillFMIfNeeded()
        refillHeartIfNeeded()
    }

    func endFMSession() {
        isFMMode = false
        fmRefilling = false
    }

    /// 剩余 ≤2 首且未在补货 → 拉一批追加队尾（Kumone 的 fmAdvance 同款语义）
    /// ★ 2026-10-17 心动模式上下文：队列将尽时按新随机种子再生（Kumone 同款）
    var heartContext: (playlistId: String, seedPool: [String])?
    private var heartRegenerating = false

    private func refillHeartIfNeeded() {
        guard heartContext != nil, !heartRegenerating, !isFMMode else { return }
        let played = (currentIndex ?? -1) + 1
        guard queue.count - played <= 2 else { return }
        heartRegenerating = true
        Task { @MainActor [weak self] in
            defer { self?.heartRegenerating = false }
            guard let self, let ctx = self.heartContext else { return }
            let seed = ctx.seedPool.randomElement()
                ?? self.queue.last?.neteaseId ?? ""
            guard !seed.isEmpty,
                  let more = try? await NeteaseMusicAPI.shared.intelligenceChain(
                      songId: seed, playlistId: ctx.playlistId, target: 20),
                  !more.isEmpty else { return }
            var seen = Set(self.queue.map { $0.keyOf })
            let fresh = more.filter { seen.insert($0.keyOf).inserted }
            if !fresh.isEmpty { self.addToQueue(fresh) }
        }
    }

    private func refillFMIfNeeded() {
        guard isFMMode, !fmRefilling else { return }
        let played = (currentIndex ?? -1) + 1
        let remaining = max(queue.count - played, 0)
        guard remaining <= 2 else { return }
        fmRefilling = true
        Task { @MainActor [weak self] in
            defer { self?.fmRefilling = false }
            guard let tracks = try? await NeteaseMusicAPI.shared.personalFMTracks(batches: 3),
                  !tracks.isEmpty, let self, self.isFMMode else { return }
            var seen = Set(self.queue.map { $0.keyOf })
            let fresh = tracks.filter { seen.insert($0.keyOf).inserted }
            if !fresh.isEmpty { self.addToQueue(fresh) }
        }
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
                // ★ 2026-10-17 用户：「无损以上音质到底是不是真无损」——
                //   请求无损/Hi-Res 档时，用 Content-Length ÷ 时长 反推码率核验
                //   （FLAC≈900-1200kbps，<850 即未达无损）。仅记日志，不影响播放。
                if AppState.shared.audioQuality.rawValue >= 2 {
                    let qName = AppState.shared.audioQuality.displayName
                    let dur = item.duration
                    let title = item.title
                    Task.detached {
                        var req = URLRequest(url: url)
                        req.httpMethod = "HEAD"
                        req.timeoutInterval = 10
                        for (k, v) in resolved.headers { req.setValue(v, forHTTPHeaderField: k) }
                        if let resp = try? await URLSession.shared.data(for: req) as? (URLResponse, Data),
                           let http = resp.0 as? HTTPURLResponse,
                           dur > 0, http.expectedContentLength > 0 {
                            let len = http.expectedContentLength
                            let kbps = Int((Double(len) * 8 / dur) / 1000)
                            let verdict = kbps >= 850 ? "✓ 达到无损" : "✗ 未达无损（可能被降级）"
                            PlayerDiag.log("音质核验 [\(qName)] \(title)：\(kbps) kbps \(verdict)")
                        }
                    }
                }
                if resolved.isFallbackSource, let name = resolved.fromCustomSource {
                    // ★ 第十一轮问题3：「自动换源：内置音源」也受内置音源提醒开关控制
                    let isBuiltin = name.contains("内置")
                    let reminderOn = (UserDefaults.standard.object(
                        forKey: MusicURLResolver.builtinReminderKey) as? Bool) ?? true
                    if !isBuiltin || reminderOn {
                        await MainActor.run { ToastCenter.shared.show("自动换源：\(name)") }
                    }
                }
                await MainActor.run {
                    // 唤醒音频会话：App 启动时 setActive 可能失败（系统繁忙/被其他
                    // App 占用），或会话在后台被抢走后被系统 deactivate —— 每次
                    // 开始播放前主动激活一次，保证后台播放 / 控件中心 / 锁屏链路完整。
                    AudioSessionManager.activate()
                    // 换歌不走淡入淡出：打断进行中的斜坡，音量拉回目标值再加载
                    // （否则旧斜坡回调会把新歌音量继续按旧目标改写）。
                    cancelFade()
                    engine.load(url: resolved.url,
                                headers: resolved.headers,
                                startAt: time,
                                autoPlay: autoPlay)
                    isPlaying = autoPlay
                    isLoading = false
                    hasActiveTrack = true
                    updateNowPlaying(item)
                    AppState.shared.recordHistory(item)
                    // ★ 网易云听歌上报：先结算上一首，再开始这一首。
                    //   只有网易云来源（且登录）才会真正发请求；其他平台静默跳过。
                    //   切歌 / 播完自动下一首 / 手动点歌都汇聚到 playCurrentItem，
                    //   所以在这里做一次即可覆盖全部场景（对齐参考 neteaseScrobble 的 switch）。
                    reportScrobbleStart(item)
                    loadLyrics(for: item)
                    // 持久化播放快照（供「启动恢复上次播放」；低频，不在 tick 里做）
                    persistPlaybackState()
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
        if fadeEnabled {
            fadeIn()
        } else {
            engine.setPaused(false)
        }
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        if fadeEnabled, !engine.isPaused {
            // 淡出：音量斜坡落到底才真暂停；位置在暂停瞬间落盘（见 fadeOutThenPause）
            fadeOutThenPause()
        } else {
            engine.setPaused(true)
            // 暂停时保存精确位置，供「启动恢复上次播放」从暂停处续播
            persistPlaybackState()
        }
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        AudioSessionManager.activate()
        if fadeEnabled {
            fadeIn()
        } else {
            engine.setPaused(false)
        }
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
        // 用户手动改音量 → 打断进行中的淡入淡出斜坡，按新音量落地
        cancelFade()
        engine.setVolume(percent: Double(volume) * 100)
    }

    // MARK: - 播放/暂停淡入淡出（2026-10-16 用户）

    /// 淡入淡出开关（UserDefaults key）
    static let fadeEnabledKey = "wellmusic.player.fadeEnabled"
    /// 淡入淡出时长（毫秒，UserDefaults key）
    static let fadeDurationKey = "wellmusic.player.fadeDurationMs"

    /// 淡入淡出档位（用户指定三档：300 / 500 / 1000 ms）
    enum PlayFadeDuration: Double, CaseIterable, Identifiable {
        case ms300 = 300
        case ms500 = 500
        case ms1000 = 1000

        var id: Double { rawValue }

        var displayName: String {
            switch self {
            case .ms300: return "0.3 秒"
            case .ms500: return "0.5 秒"
            case .ms1000: return "1 秒"
            }
        }
    }

    /// 斜坡定时器（与 `tickTimer` 同款 Timer + RunLoop.common 模式）
    private var fadeTimer: Timer?
    /// 斜坡代数：每次新斜坡 +1，旧定时器回调发现代数不符即静默退出
    /// （防用户快速连点播放/暂停时两条斜坡互相打架）。
    private var fadeGeneration = 0

    private var fadeEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.fadeEnabledKey)
    }

    private var fadeDuration: TimeInterval {
        let ms = UserDefaults.standard.double(forKey: Self.fadeDurationKey)
        return (ms > 0 ? ms : 500) / 1000
    }

    /// 目标音量（mpv 百分比 0~100）。与 `PlayerServiceBridge` 写入的
    /// "player.volume" 同源；从未写过按 100% 算（见 `restoredVolume` 的迁移说明）。
    private var targetVolumePercent: Double {
        let d = UserDefaults.standard
        let v: Float = d.object(forKey: "player.volume") != nil ? d.float(forKey: "player.volume") : 1.0
        return Double(min(max(v, 0), 1)) * 100
    }

    /// 取消进行中的音量斜坡，并把音量拉回目标值。
    private func cancelFade() {
        fadeGeneration &+= 1
        fadeTimer?.invalidate()
        fadeTimer = nil
        engine.setVolume(percent: targetVolumePercent)
    }

    /// 淡入：音量 0 → 目标值（默认 0.5s 斜坡，约 30fps）。
    private func fadeIn() {
        cancelFade()
        let duration = fadeDuration
        let target = targetVolumePercent
        guard fadeEnabled, duration > 0.05, target > 0 else {
            engine.setPaused(false)
            return
        }
        engine.setVolume(percent: 0)
        engine.setPaused(false)
        startFadeRamp(from: 0, to: target, duration: duration) { [weak self] in
            self?.engine.setVolume(percent: target)
        }
    }

    /// 淡出：音量当前值 → 0，落到底再真暂停。
    private func fadeOutThenPause() {
        cancelFade()
        let duration = fadeDuration
        // 起点取 mpv 真值：可能正处在淡入中途被打断（避免先跳响再渐弱）
        let from = engine.volumePercent ?? targetVolumePercent
        guard fadeEnabled, duration > 0.05, from > 0 else {
            engine.setPaused(true)
            return
        }
        startFadeRamp(from: from, to: 0, duration: duration) { [weak self] in
            self?.engine.setPaused(true)
            // 位置在真正暂停时落盘（斜坡期间 time-pos 还在走）
            self?.persistPlaybackState()
        }
    }

    /// 起一条音量斜坡定时器。`completion` 只在斜坡自然结束时调用；
    /// 被 `cancelFade` 打断时静默丢弃（不再补刀）。
    private func startFadeRamp(from: Double, to: Double, duration: TimeInterval,
                               completion: @escaping @MainActor () -> Void) {
        fadeGeneration &+= 1
        let generation = fadeGeneration
        let steps = max(2, Int((duration / 0.033).rounded()))
        var step = 0
        let t = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if generation != self.fadeGeneration {
                    self.fadeTimer?.invalidate()
                    self.fadeTimer = nil
                    return
                }
                step += 1
                if step >= steps {
                    self.fadeTimer?.invalidate()
                    self.fadeTimer = nil
                    completion()
                } else {
                    let ratio = Double(step) / Double(steps)
                    self.engine.setVolume(percent: from + (to - from) * ratio)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    func next() {
        guard !queue.isEmpty else { return }
        // ★ 私人漫游：推进时按剩余量自动补货（原来播完就停）
        refillFMIfNeeded()
        refillHeartIfNeeded()
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

    /// 「下一首播放」（2026-10-16 用户）：插到当前曲目后面；无当前曲目则追加队尾。
    func playNext(_ item: MusicItem) {
        if let idx = currentIndex {
            queue.insert(item, at: min(idx + 1, queue.count))
        } else {
            queue.append(item)
        }
    }

    // MARK: 0.05s tick（位置 / 时长 / 渲染态）

    private var tickTimer: Timer?

    /// 上一 tick 的渲染态（检测「刚开始渲染」的上升沿，见 tick()）
    private var wasRenderingAudio = false

    /// 上次**音频会话巡检**的时刻（限频 5s/次 —— 见 tick() 的守卫）。
    ///
    /// ⚠️ 2026-10-14 16:18 修正：这个闸门现在同时约束「读取」与「自愈」。原先读取
    /// （`AVAudioSession.category`）在闸门之外、每 tick 都做，20Hz 跨进程查询常驻 →
    /// 播放中每个页面都掉帧。自愈时机不变：本来也只有闸门放行的那一次才可能自愈。
    private var lastSessionGuardAt: TimeInterval = 0

    /// 上次断流自动恢复的时刻（冷却防死循环）
    private var lastAutoReloadAt: TimeInterval = 0

    /// 已为哪首歌补过 NowPlaying 封面图（每首歌只异步拉一次，暂停/恢复不重复下载）
    private var nowPlayingArtworkKey: String?
    /// 已下载的封面（同歌多次更新 nowPlayingInfo 时复用，避免整块信息被无图覆盖）
    private var nowPlayingArtwork: MPMediaItemArtwork?
    /// 是否已成功向系统写入过 NowPlaying 信息（用于 tick 兜底补写）
    private var hasPublishedNowPlaying = false

    // MARK: 控制中心歌词（用户 2026-10-15，默认关）

    /// 控制中心 / 锁屏「艺人」位改显示歌词的开关键（默认关）。
    nonisolated static let nowPlayingLyricsKey = "wellmusic.player.nowPlayingLyrics"

    /// 开关当前值（启动时读一次；设置页切换由 `setNowPlayingLyricsEnabled(_:)` 同步）。
    private var nowPlayingLyricsEnabled =
        UserDefaults.standard.bool(forKey: PlayerCore.nowPlayingLyricsKey)
    /// 已写进 NowPlaying「艺人」位的歌词行文本（跨行才重写，见 tick）。
    private var nowPlayingLyricLine: String?

    /// 设置页开关：控制中心 / 锁屏的歌手名位置改成显示当前歌词行（默认关）。
    ///
    /// 切换后立即重写 NowPlaying：关 → 立刻退回歌手名（不等下一句歌词）；
    /// 开 → 先回落歌手名，50ms 内的 tick 会把当前歌词行补上。
    func setNowPlayingLyricsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.nowPlayingLyricsKey)
        guard enabled != nowPlayingLyricsEnabled else { return }
        nowPlayingLyricsEnabled = enabled
        nowPlayingLyricLine = nil
        if hasActiveTrack { updateNowPlaying() }
    }

    // MARK: 网易云听歌上报（scrobble）状态

    /// 当前曲目的网易云 song id（只有网易云来源的歌才会上报）。
    private var scrobbleNeteaseId: Int?
    /// 当前曲目开始播放的时刻（用于算「播放了多少秒」再上报）。
    private var scrobbleStartedAt: Date?

    // MARK: 播放状态持久化（启动恢复上次播放）

    /// 可恢复的播放快照（队列 + 当前曲目索引 + 播放位置）。
    ///
    /// ⚠️ 不存 `MusicItem.playURL` 之外的解析结果 —— 音源链接有有效期，
    /// 恢复时**必须重新解析**（见 `restorePlaybackIfNeeded`），否则拿过期链接播放必失败。
    private struct PlaybackSnapshot: Codable {
        var queue: [MusicItem]
        var currentIndex: Int
        var currentTime: TimeInterval
    }

    private static let snapshotKey = "wellmusic.player.lastSnapshot"

    /// 把当前播放状态写入 UserDefaults（低频调用，绝不在 20Hz tick 里做）。
    private func persistPlaybackState() {
        guard !queue.isEmpty, let idx = currentIndex, queue.indices.contains(idx) else {
            UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
            return
        }
        let snapshot = PlaybackSnapshot(queue: queue, currentIndex: idx, currentTime: currentTime)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        }
    }

    /// 冷启动时恢复上次播放（开关开启 + 有快照才做）。
    ///
    /// 恢复的是**列表与位置**，播放地址一律重新解析（`playCurrentItem` 内部
    /// 走 `MusicURLResolver`，不会用到任何过期链接）。
    func restorePlaybackIfNeeded() {
        guard SettingsManager.shared.restoreLastPlayback else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data),
              !snapshot.queue.isEmpty else { return }
        // 有活跃曲目就不再重复恢复（避免覆盖用户当前播放）
        guard !hasActiveTrack else { return }
        queue = snapshot.queue
        currentIndex = snapshot.queue.indices.contains(snapshot.currentIndex)
            ? snapshot.currentIndex : 0
        // seekTo 要落到有效位置：位置贴近结尾时从头播，避免「一恢复就结束」
        let dur = snapshot.queue[currentIndex ?? 0].duration
        let seekTo = (dur > 0 && snapshot.currentTime >= dur - 3) ? 0 : snapshot.currentTime
        playCurrentItem(seekTo: seekTo, autoPlay: true)
    }

    // MARK: 网易云听歌上报（scrobble）

    /// 开始播一首歌：先结算上一首（若还在），再对当前曲目发起 `startplay` 上报。
    ///
    /// 语义对齐参考 `neteaseScrobble.scrobbleSwitch`：
    /// `startplay` → 写入网易云「最近播放」；`play` → 累加「听歌排行」次数与时长。
    /// 只处理网易云来源（`neteaseId` 可解析成 Int）且已登录，否则静默跳过。
    private func reportScrobbleStart(_ item: MusicItem) {
        // 结算上一首
        if let prevId = scrobbleNeteaseId, let started = scrobbleStartedAt {
            let seconds = Int(Date().timeIntervalSince(started))
            if seconds > 0 {
                Task { await NeteaseMusicAPI.shared.scrobbleFinish(neteaseTrackId: String(prevId), seconds: seconds) }
            }
        }
        scrobbleNeteaseId = nil
        scrobbleStartedAt = nil

        // 开始这一首（只有网易云来源才上报）
        let unwrapped = item.source == .lx ? item.unwrappedFromCustomSource() : item
        guard unwrapped.source == .netease,
              let nid = unwrapped.neteaseId, let _ = Int(nid),
              NeteaseSession.shared.isLoggedIn else { return }
        scrobbleNeteaseId = Int(nid)
        scrobbleStartedAt = Date()
        Task { await NeteaseMusicAPI.shared.scrobbleStart(neteaseTrackId: nid) }
    }

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
            // ★ 2026-10-14 用户：「修复睡眠定时」。
            //   「当前歌曲结束时停止」原先是在 UI 侧用 `duration - currentTime` 猜倒计时，
            //   duration 未就绪时会立刻暂停。真正的触发点就在**这里**：
            //   本曲自然播完时先问睡眠定时是否处于「本曲结束」模式 —— 是则暂停且不切歌。
            if PlayerService.shared.sleepTimer.consumeEndOfCurrentTrack() {
                PlayerDiag.log("睡眠定时：本曲已结束 → 暂停（不切下一首）")
                pause()
                return
            }
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
        // ★ 音频会话守卫（加固 + 限频修复）：
        //   mpv 的 AudioUnit 音频输出在 AO 初始化 / seek / 重建时会把会话改跑，
        //   类别不是 `.playback` **或**被加上了 `.mixWithOthers` 时，系统不认
        //   「媒体播放」——控制中心 / 锁屏不出现（后者是 2026-10-14 定位的真根因，
        //   详见 `AudioSessionManager` 的注释）。
        //
        //   ⚠️ 必须**限频（5s/次）**：若类别被持续改跑、自愈又失败，20Hz 的
        //   setCategory/setActive（外加 nowPlayingInfo 写入）会反复打断音频
        //   会话 —— 实机表现就是「更新之后好卡掉帧」（2026-10-14 用户反馈）。
        //   空闲时（无活跃曲目）不巡检，避免无谓的后台扰动。
        if hasActiveTrack {
            let now = Date().timeIntervalSinceReferenceDate
            // ⚠️★ 时间闸门必须**盖住读取本身**（2026-10-14 16:18 第二轮排查）：
            //   `AVAudioSession.category` 不是内存里的缓存值，读一次要问音频系统
            //   （mediaserverd）。上一版只把「自愈动作」限频到 5s，读取仍留在 20Hz ——
            //   播放期间每秒 20 次主线程跨进程查询常驻，与 10Hz 的输出延迟测量叠加，
            //   这正是「每个页面滑动都掉帧」里最可疑的一项。
            //   现在把闸门提到读取之前（一次闸门 = 一次读取），自愈时机与限频语义不变
            //   —— 因为原先自愈本来就被同一个 5s 条件挡着。
            if now - lastSessionGuardAt > 5 {
                lastSessionGuardAt = now
                if AudioSessionManager.needsRepair {
                    PlayerDiag.log("音频会话巡检发现偏离（\(AudioSessionManager.stateDescription)）→ 拉回目标形态")
                    AudioSessionManager.activate()
                    updateNowPlaying()
                }
            }
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
        // ★ 控制中心歌词（用户 2026-10-15，默认关）：开启时把当前歌词行写进
        //   NowPlaying 的「艺人」位。只在**跨行**时重写 —— 20Hz 每 tick 写
        //   nowPlayingInfo 是纯浪费（字典重建 + 系统侧刷新）。
        //   关着的时候整个块被第一个条件短路，零开销。
        if nowPlayingLyricsEnabled, hasActiveTrack {
            // 用 displayTime（拖动中 = 预览时间）+ 全局歌词偏移，与歌词页同一口径
            let line = currentLyricLineText(at: displayTime + AppState.shared.lyricOffset)
            if line != nowPlayingLyricLine {
                nowPlayingLyricLine = line
                updateNowPlaying()
            }
        }
        // ★ 预加载下一首：播放到 5 秒时，后台把下一首的播放地址解析好并缓存，
        //   用户点「下一首」时可以直接用缓存地址起播，消除解析等待（响应更跟手）。
        //
        // ⚠️★ 闸门必须落在「**当前曲目**」而不是「下一首是否已经预加载」
        //   （2026-10-14 用户报「音源状态 → 最近请求一直在自动跳」）：
        //   随机播放模式下 `nextTrack` 每次求值都会 `randomElement()` 重新挑一首，
        //   于是 `preloadedTrackKey != nextTrack?.keyOf` 几乎**每个 tick 都成立** ——
        //   `preloadNext()` 被 20Hz 反复触发：每秒约 20 次地址解析
        //   （`WellLXSourceStore` 是 @MainActor，解析全程在主线程排队 → 播放就掉帧严重），
        //   且每次都往请求日志顶部插一条（列表因此「一直在自动跳」）。
        //   改成「每首当前曲目最多尝试一次」：任何播放模式下都恒定只发一次；
        //   顺带去掉随机模式下「预加载的那首其实不是真正下一首」的无效功。
        if hasActiveTrack, !isLoading, !isScrubbing, currentTime >= 5,
           SettingsManager.shared.preloadNextEnabled,
           let playingKey = currentItem?.keyOf, preloadAttemptedTrackKey != playingKey {
            preloadAttemptedTrackKey = playingKey
            preloadNext()
        }
    }

    // MARK: 预加载下一首

    /// 已经为哪一首**当前曲目**发起过预加载尝试（值 = `MusicItem.keyOf`）。
    /// ⚠️ 闸门用「当前曲目」而非「下一首是否已预加载」—— 原因见 tick() 里的说明。
    private var preloadAttemptedTrackKey: String?

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
        // ★ 显式启用全部命令（2026-10-14 加固，「控制中心不显示」排查项之一）。
        //
        // 只 addTarget 不显式 isEnabled = true 时，部分 iOS 版本会把命令视为
        // 「未启用」—— 系统据此判定 App 不提供媒体控制，控制中心的播放卡片
        // 整块不出现。addTarget 与 isEnabled 两道都要有。
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        // ★★ 2026-10-14 用户：「控制中心在播放歌曲没有五角星收藏按钮」。
        //
        //   iOS 的 Now Playing 卡片（控制中心 / 锁屏）**只在 App 注册了 `likeCommand`
        //   时才会画出那个收藏按钮** —— 光有 play / pause / next / previous 是不会出现的。
        //   这里把它接到本项目「我喜欢」的收藏状态上；`isActive` 用当前曲目是否已收藏
        //   来反映（见 `refreshLikeCommand()`），按钮才会呈现选中/未选中两种样子。
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = "收藏"
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
        center.likeCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            return self.handleLikeCommand()
        }
    }

    /// 控制中心 / 锁屏「收藏」按钮 → 当前曲目加入/移出「我喜欢」。
    @discardableResult
    private func handleLikeCommand() -> MPRemoteCommandHandlerStatus {
        guard let item = currentItem else { return .noActionableNowPlayingItem }
        AppState.shared.toggleFavorite(item)
        refreshLikeCommand()
        ToastCenter.shared.show(AppState.shared.isFavorite(item) ? "已收藏" : "已取消收藏")
        return .success
    }

    /// 让控制中心 / 锁屏的收藏按钮反映**当前曲目是否已收藏**。
    func refreshLikeCommand() {
        guard let item = currentItem else {
            MPRemoteCommandCenter.shared().likeCommand.isActive = false
            return
        }
        MPRemoteCommandCenter.shared().likeCommand.isActive = AppState.shared.isFavorite(item)
    }

    private func updateNowPlaying(_ item: MusicItem? = nil) {
        let song = item ?? currentItem
        guard let song else { return }

        let center = MPNowPlayingInfoCenter.default()
        let isNewSong = nowPlayingArtworkKey != song.keyOf
        if isNewSong {
            nowPlayingArtworkKey = song.keyOf
            nowPlayingArtwork = nil     // 换歌即作废上一首封面，防止错配
            nowPlayingLyricLine = nil   // 换歌即作废上一首歌词行，新歌歌词由 tick 补上
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
        PlayerDiag.log("NowPlaying 更新 title=\(song.title) playing=\(isPlaying) dur=\(String(format: "%.1f", duration)) state=\(center.playbackState.rawValue) \(AudioSessionManager.stateDescription)")
        // ④ 收藏按钮状态（控制中心 / 锁屏）：换成别的歌就立刻重算一次
        refreshLikeCommand()

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
    ///
    /// ★ 用户 2026-10-15：控制中心歌词开关（默认关）打开时，「艺人」位改填
    /// 当前歌词行文本；没有可用歌词行（无歌词 / 首行之前 / 纯音乐空行）时回落歌手名。
    private func nowPlayingInfo(for song: MusicItem) -> [String: Any] {
        let artistText = (nowPlayingLyricsEnabled ? nowPlayingLyricLine : nil)
            ?? song.artist ?? "未知艺术家"
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: artistText,
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

    /// 当前时间对应的歌词行文本（控制中心歌词用）。没有歌词 / 在首行之前 /
    /// 空行（纯音乐占位）→ nil，由调用方回落歌手名。
    ///
    /// `AppState.currentLrc` 按 `time` 升序（LRC 解析保证），二分找最后一个
    /// `time <= 当前时间` 的行。放在 tick（20Hz）里跑，必须 O(log n) ——
    /// 线性扫一遍上千行歌词每个 tick 都做，就是新一轮掉帧源。
    private func currentLyricLineText(at time: TimeInterval) -> String? {
        let lines = AppState.shared.currentLrc
        guard !lines.isEmpty else { return nil }
        var lo = 0
        var hi = lines.count - 1
        var found: LrcLine?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time {
                found = lines[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let line = found else { return nil }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
