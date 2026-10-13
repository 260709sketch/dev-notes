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

    func playCurrentItem(seekTo time: TimeInterval, autoPlay: Bool = true, preferOfficial: Bool = false, isReload: Bool = false) {
        guard let item = currentItem else { return }
        isLoading = true
        currentTime = time
        if item.duration > 0 { duration = item.duration }
        // 换曲目 / 重新解析：清除「官方通道已重试」标记，新歌可再次检测试听。
        // ⚠️ 断流重载（isReload）**不清**：重载是同一首歌的续播，清掉会让
        //    LX 重新给出试听链接时再次触发「试听拦截 → 官方重播 seekTo 0」，
        //    表现即「拖动进度条后歌曲跳回开头」。
        if !preferOfficial, !isReload {
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
                // 解析失败（LX 源偶发限流 / 官方接口抖动）：明确提示。
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

    /// 上次断流自动恢复的时刻（冷却防死循环）
    private var lastAutoReloadAt: TimeInterval = 0
    /// 已尝试过「官方通道重播」的曲目 key（防试听检测无限循环）
    private var officialRetriedTrackKey: String?

    /// 已为哪首歌补过 NowPlaying 封面图（每首歌只异步拉一次，暂停/恢复不重复下载）
    private var nowPlayingArtworkKey: String?
    /// 已下载的封面（同歌多次更新 nowPlayingInfo 时复用，避免整块信息被无图覆盖）
    private var nowPlayingArtwork: MPMediaItemArtwork?

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

        // ★★★ 拖动 seek 噪音窗口：用户 seek 后 8s 内的 END_FILE（EOF/error）
        //    全部视为「CDN 掐断」的预期噪音 —— **一律重载续播**，跳过所有
        //    nearEnd 判定 / 试听检测 / next() / 官方重播。
        //    这是「一拖动就自动切歌」的总开关：seek 后任何自动切歌机制都不允许生效。
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
        //
        // ⚠️ 双保险：还要求 mpv 报告的 duration 与歌曲元数据时长**接近**（差 <15s）。
        // 某些 CDN / 试听链路的容器元数据时长是错的（报出 15~30s 的假时长），
        // 播到「duration - 5」就满足 nearEnd → 被误判成播完 → 无声切下一首。
        // 元数据对不上的一律不算播完，交给 ①（试听重播）、②b 或 ③（断流重载）。
        //
        // ⚠️ 元数据时长缺失（LX 源常见 item.duration == 0）时**绝不能无条件放行**：
        // 旧逻辑「guard ... else return true」会让「无元数据的试听片段」直接命中
        // 自然播完 → 自动切歌（「播放十几秒就自动播放下一首」的隐蔽路径）。
        // 缺失时改用**流时长**做保守判定：60s 以上视为正常长度的完整音频放行；
        // 以下视作试听/截断嫌疑，交由 ②b（先试官方通道，仍短则停住）。
        let nearEnd = duration > 0 && currentTime >= duration - 5
        let durationMatchesMeta: Bool = {
            guard let item = currentItem else { return true }
            guard item.duration > 0, duration > 0 else {
                return duration >= 60
            }
            return abs(item.duration - duration) < 15
        }()

        if reason == .eof, nearEnd, durationMatchesMeta {
            PlayerDiag.log("自然播完 pos=\(String(format: "%.1f", currentTime)) dur=\(String(format: "%.1f", duration)) → 下一首")
            next()
            return
        }

        // ②b EOF 且到了文件结尾、但时长与元数据对不上：
        //    - 未尝试过官方通道 → 官方重播（试听片段的兜底分支：差 15~20s 的
        //      短文件 ① 的 ">20s" 条件抓不到，这里补上）
        //    - 已尝试过 → 确认这就是该平台能给的**最长版本**（如 VIP 歌只剩试听）。
        //      ★ 不再自动 next()：官方通道也拿不到完整版时，「自动播下一首」让用户
        //        产生「歌没听完就被切走」的丢失感（连播时连续发生，非常严重）。
        //        改为【停在当前曲目】：重载并保持暂停（EOF 后 mpv 已卸载文件，
        //        不重载则「按播放」无响应），回到开头等用户决定去留。
        if reason == .eof, nearEnd, !durationMatchesMeta, let item = currentItem {
            if officialRetriedTrackKey != item.keyOf {
                officialRetriedTrackKey = item.keyOf
                PlayerDiag.log("短文件检测（试听/截断）dur=\(String(format: "%.1f", duration)) meta=\(String(format: "%.1f", item.duration)) → 官方通道重播完整版")
                ToastCenter.shared.show("已切换为完整版播放")
                playCurrentItem(seekTo: 0, autoPlay: true, preferOfficial: true)
            } else {
                PlayerDiag.log("已确认仅试听片段 pos=\(String(format: "%.1f", currentTime)) dur=\(String(format: "%.1f", duration)) meta=\(String(format: "%.1f", item.duration)) → 停住（不自动切歌）")
                ToastCenter.shared.show("该歌曲仅提供试听片段，已停止自动切换")
                playCurrentItem(seekTo: 0, autoPlay: false, isReload: true)
            }
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
        // ★ 试听片段**事前拦截**：LX 音源对 VIP/无版权歌曲返回 15~30s 试听链接，
        //   播放开始 1~2 秒内 mpv 就能报告真实 duration。一旦发现真实时长远短于
        //   歌曲元数据（短 20s+ 且未尝试过官方通道），立即换官方通道重播，
        //   而不是等播完试听才发现（用户几乎无感）。
        //   ⚠️ seek 噪音窗口内不触发：拖动后的重载文件 duration 报告尚不稳定，
        //   且重载场景下用户已在目标位置听，绝不允许被拽回 0。
        if !isScrubbing, !isWithinSeekNoiseWindow,
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
            // 播放/暂停态变化 → 同步锁屏 / 控制中心（rate 与状态保持一致）
            updateNowPlaying()
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

        let center = MPNowPlayingInfoCenter.default()
        let isNewSong = nowPlayingArtworkKey != song.keyOf
        if isNewSong {
            nowPlayingArtworkKey = song.keyOf
            nowPlayingArtwork = nil     // 换歌即作废上一首封面，防止错配
        }

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
        center.playbackState = hasActiveTrack ? (isPlaying ? .playing : .paused) : .stopped
        PlayerDiag.log("NowPlaying 更新 title=\(song.title) playing=\(isPlaying) dur=\(String(format: "%.1f", duration))")

        // ③ 封面图：每首歌只异步拉一次（走 WellImageCache 的缩图缓存，与列表/播放页
        //    共用同一份解码结果），到图后补写同一条信息；失败则保持无封面，不影响显示。
        guard isNewSong, let coverURL = WellArtworkURL.resolved(song.albumCoverURL, pixelSize: 1024) else { return }
        Task { [weak self] in
            guard let image = await WellImageCache.shared.image(for: coverURL) else { return }
            guard let self, self.currentItem.map({ MusicItem.isSame($0, song) }) ?? false else { return }
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
    private func nowPlayingInfo(for song: MusicItem) -> [String: Any] {
        [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "未知艺术家",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
    }
}
