import Foundation
import SwiftUI
import Combine
import AVFoundation

// MARK: - PlayerClock
/// 可观测的播放时钟。
///
/// ⚠️ **默认不启动**（见 `PlayerService.init` 的说明）。
///
/// 它用一个 20Hz（50ms）的 `Timer` + `Task { @MainActor }`
/// 双层派发，把 `PlayerCore.displayTime` 转发成 `@Published progress`。
/// 但本项目**已经有** `PlayerCore.currentTime`（同样是 20Hz，由
/// `addPeriodicTimeObserver` 驱动，且是直接赋值、少一层派发）——两者是**同一份数据**。
///
/// 两个 20Hz 时钟同时跑，意味着每秒 40 次主线程唤醒 + 视图重算；而播放页顶层
/// 只要观察了 `clock`，整个播放器页（含 WKWebView 与 WebGL 背景）就会每 50ms
/// 全量重算一次，直接导致「一打开播放器就卡死」。
///
/// 现在活代码里已经**没有**任何视图观察 `clock`：
///   * 进度条 `PlayerSeekBar` 直接观察 `PlayerCore`
///   * 歌词高亮走 `LyricsCursor.activeIndex`（只在换行时通知，低频）
/// 所以它是纯粹的空转开销，不再启动。保留类型以兼容既有调用点。
@MainActor
final class PlayerClock: ObservableObject {
    @Published var progress: TimeInterval = 0

    private var timer: Timer?

    /// 是否真的在跑。默认 `false`：无人观察时不该有任何定时器。
    private(set) var isRunning = false

    func start() {
        // 有意保持空实现。若将来确实需要独立时钟，把下面的代码放回来，
        // 但**必须**先确认没有任何大范围视图观察它。
        //
        // stop()
        // timer = Timer.scheduledTimer(...)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }
}

// MARK: - LyricsCursor
/// 当前歌词行游标，根据播放时间计算 activeIndex。
@MainActor
final class LyricsCursor: ObservableObject {
    @Published var activeIndex: Int? = nil
    @Published var lyrics: ParsedLyrics = ParsedLyrics()

    func updateLyrics(_ parsed: ParsedLyrics) {
        self.lyrics = parsed
        activeIndex = parsed.lines.isEmpty ? nil : 0
    }

    func updateProgress(_ time: TimeInterval, offset: TimeInterval) {
        // ⚠️★ 2026-10-14 用户：「睡眠定时我怎么刚打开自己就关闭了」——根因就在这一行。
        //
        // 本类型存在的**全部意义**就是「只在当前行号真的变化时才通知」
        // （`syncFromCore` 以 10Hz 调本方法；见 `AppleMusicPlayerView.currentPlaybackLyricIndex`
        // 的注释：靠这个把播放页重算频率从 20Hz 降到「一句歌词一次」）。
        //
        // 但原先这里是 `guard !lyrics.lines.isEmpty else { activeIndex = nil; return }` ——
        // 无条件赋值。`@Published` **不比较新旧值**，每次赋值都会发
        // `objectWillChange`。于是只要**歌词为空**（这首歌没有歌词 / 歌词尚未加载完），
        // 播放页顶层（观察了 `lyricsCursor`）就以 **10Hz** 全量重算：
        //   * AMLL 的 WKWebView / WebGL 背景 / 控制栏全部陪跑（白耗电 + 掉帧）；
        //   * 正在展开的 `Menu` 会被 SwiftUI 重建而**立刻收起** —— 而「睡眠定时」
        //     是三点菜单里**唯一**的子菜单，所以只有它暴露症状（普通按钮点了就走，不受影响）。
        // 修法：和下面那段一样，比较后再写。
        guard !lyrics.lines.isEmpty else {
            if activeIndex != nil { activeIndex = nil }
            return
        }
        let adjusted = time + offset
        var idx = 0
        for (i, line) in lyrics.lines.enumerated() {
            if line.time <= adjusted {
                idx = i
            } else {
                break
            }
        }
        if idx != activeIndex {
            activeIndex = idx
        }
    }
}

// MARK: - SleepTimer
/// 睡眠定时器：schedule(afterMinutes:) / scheduleAtEndOfCurrentTrack() / cancel()
///
/// ★ 2026-10-14 用户：「修复下睡眠定时」。原实现有两处硬伤：
///   ① 「当前歌曲结束时停止」是用 `duration - currentTime` **猜一个倒计时** ——
///      duration 还没读到时 remaining = 0，点一下就会立刻暂停；换歌/暂停也会算错。
///   ② 用 `Timer` 计时，且没有任何防竞态手段。
///   现改成真实状态机（`Core/Player/SleepTimer.swift`）：
///   * `.countdown(deadline:)` 用 `Task.sleep` 计时（可取消 + generation 防竞态），
///     状态里带 deadline，UI 可以据此显示「剩余 xx」；
///   * `.endOfCurrentTrack` **不再自己计时**，只置状态；真正的触发由播放内核在
///     本曲自然播完时调用 `consumeEndOfCurrentTrack()` 完成
///     （见 `PlayerCore.handleTrackEnded`）。
@MainActor
final class SleepTimer: ObservableObject {
    enum State: Equatable {
        case inactive
        case countdown(deadline: Date)
        case endOfCurrentTrack

        var isActive: Bool { self != .inactive }
    }

    @Published private(set) var state: State = .inactive

    private var deadlineTask: Task<Void, Never>?
    private var generation = 0

    func schedule(afterMinutes minutes: Int) {
        guard minutes > 0 else { return }

        generation += 1
        let scheduledGeneration = generation
        deadlineTask?.cancel()

        let seconds = TimeInterval(minutes * 60)
        state = .countdown(deadline: Date().addingTimeInterval(seconds))
        deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return   // 被 cancel() / 重新 schedule 打断
            }
            guard let self, !Task.isCancelled, self.generation == scheduledGeneration else { return }
            self.deadlineTask = nil
            self.state = .inactive
            // 到点语义 = 暂停播放
            PlayerCore.shared.pause()
        }
    }

    /// 「当前歌曲结束时停止」：只置状态，触发点在曲末。
    func scheduleAtEndOfCurrentTrack() {
        generation += 1
        deadlineTask?.cancel()
        deadlineTask = nil
        state = .endOfCurrentTrack
    }

    func cancel() {
        generation += 1
        deadlineTask?.cancel()
        deadlineTask = nil
        state = .inactive
    }

    /// 由播放内核在本曲**自然播完**时调用。
    /// 返回 true = 应该暂停，且**不要**切下一首。
    func consumeEndOfCurrentTrack() -> Bool {
        guard state == .endOfCurrentTrack else { return false }
        cancel()
        return true
    }
}

// MARK: - PlayerService
/// 桥接 PlayerCore 的 facade，满足 AppleMusicPlayerView 对 PlayerService 的依赖契约。
@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    // MARK: - Sub-services
    let clock = PlayerClock()
    let lyricsCursor = LyricsCursor()
    let sleepTimer = SleepTimer()

    // MARK: - Published state (derived from PlayerCore + AppState)

    @Published private(set) var currentTrack: Track?
    @Published private(set) var lyrics: ParsedLyrics?
    @Published private(set) var hasCurrentTrack: Bool = false
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isBuffering: Bool = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var shuffleEnabled: Bool = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published var volume: Float {
        didSet {
            AVAudioSession.activateIfNeeded()
            UserDefaults.standard.set(volume, forKey: "player.volume")
            // MPV 内核：直接下发到引擎的 volume 属性（0~100）
            PlayerCore.shared.applyVolume(volume)
        }
    }
    @Published var isMuted: Bool = false

    /// AMLL 歌词页的时间源（秒），**同步即时**。
    ///
    /// 拖动中用 `scrubTime`（跟手），其余直接读 `AVPlayer.currentTime()`
    /// （即 `PlayerCore.playerPosition`，不经任何轮询缓存）。
    ///
    /// ⚠️ 这里**不能**沿用 `PlayerCore.displayTime`（= `currentTime`）。
    ///
    /// `currentTime` 由 `addPeriodicTimeObserver` 维护，而传入的 0.05s 只是
    /// 「**至少**这么频繁」—— **无损 / Hi-Res 大文件上实际回调会被明显拉长**。
    /// 更要命的是 AMLL 页面的 `sync` 是**无条件** `co = ms`：每推送一次就把
    /// 外推基准重置成这个滞后值。于是歌词被持续钉在滞后位置上，
    /// **无论重锚多少次都追不上** —— 这正是「拖完进度条歌词慢半拍」的根因。
    /// 换成同步值后，每一次推送本身就是准确基准，滞后当场消失。
    var livePlaybackTime: TimeInterval {
        let core = PlayerCore.shared
        if core.isScrubbing { return core.scrubTime }
        return core.playerPosition
    }

    /// 歌词时钟专用的**精确**锚点。
    ///

    /// 与 `livePlaybackTime`（= `displayTime`）的关键区别：
    /// `displayTime` 在拖动结束后会**乐观地**立刻返回 `currentTime`，而 `currentTime` 是
    /// 「上一次 AVPlayer 周期回调报告的位置」——无损 / Hi-Res 文件上该回调间隔明显拉长，
    /// 于是松手瞬间 `displayTime` 可能比播放器真实位置**滞后上百毫秒**。
    ///
    /// 拖动时滞后无关紧要（时间由 `scrubTime` 提供）；但松手后的硬校准锚点必须精确，
    /// 否则 AMLL 会以这个滞后值为起点重新外推，一路偏移下去。
    /// 所以这里直接读 `player.currentTime()`（同步、即时、不经过 0.1s 轮询缓存）。
    var precisePlaybackTime: TimeInterval {
        PlayerCore.shared.playerPosition
    }

    // MARK: - 输出延迟（让歌词对齐到「耳朵听到的时刻」）

    /// 当前音频输出链路的**实测**延迟（秒）。
    ///
    /// ## 这是「歌词看着和听到的人声错开」在 iOS 上最常见的成因
    ///
    /// 播放器报告的 `position` 是「音频系统**已经喂给输出**」的位置，而声音还要经过
    /// 输出缓冲才到耳朵 —— 两者差的就是这个值：
    /// * 内建扬声器 / 有线：一般 10–30ms（基本可忽略）
    /// * **蓝牙 A2DP：常见 150–250ms**
    /// * AirPlay：可达 1–2 秒
    ///
    /// 这个量级足以让逐字歌词明显对不上，而且**任何播放内核都躲不掉** ——
    /// 它是硬件/系统输出缓冲，不是解码或 seek 的问题（换 MPV 也一样）。
    ///
    /// iOS 直接给了实测值（`outputLatency` + `ioBufferDuration`），所以**不需要让用户手动猜**。
    /// 之前「歌词偏移」面板下面写着「用于校准蓝牙耳机等设备的输出延迟」，说的就是这个数 ——
    /// 现在由这里自动补上，用户的偏移只作为**额外**微调。
    /// UI 显示用的输出延迟（低频发布）。
    ///
    /// ⚠️★ 2026-10-15 用户：「播放器界面在放歌时，睡眠定时打开之后每两秒自动关闭」。
    /// 根因：播放中 `AVAudioSession.outputLatency` 读数**持续微抖**，而旧代码每 2s 兜底
    /// 测量后只要抖动 > 1ms 就写这个 `@Published` → 播放页每 2s 全量重算 → 展开中的
    /// `Menu` 被 SwiftUI 重建而立刻收起（睡眠定时是唯一的子菜单，只有它暴露症状）。
    /// 修法：**拆两个值** —— 计算用 `liveLatency`（实时、不发布），UI 显示用本值
    /// （变化 ≥ 50ms 才发布，人耳/人眼对 50ms 内的偏移无感知）。
    @Published private(set) var outputLatency: TimeInterval = 0

    /// 实时输出延迟（歌词对齐计算用；不发布，避免周期性重算播放页）。
    private(set) var liveLatency: TimeInterval = 0

    // MARK: - 歌词偏移（按曲记忆）

    /// 当前歌曲的歌词偏移 key（"平台|平台内id"）。
    var currentSongOffsetKey: String? {
        guard let t = currentTrack else { return nil }
        return AppState.songOffsetKey(sourcePlatform: t.sourcePlatform, platformId: t.platformSongId)
    }

    /// 生效歌词偏移：调整过的歌 = 专属值；未调整过 = 全局值。
    var effectiveLyricOffset: Double {
        AppState.shared.effectiveLyricOffset(forKey: currentSongOffsetKey)
    }

    /// 上次实测输出延迟的时刻（限频闸门，见 `refreshOutputLatency`）。
    private var lastLatencyMeasureAt: TimeInterval = 0
    /// 输出路由变化观察者（插拔耳机 / 连蓝牙 / 切 AirPlay → 立刻重测）
    private var routeObserver: NSObjectProtocol?

    /// 重新测量输出延迟。
    ///
    /// ⚠️ 必须**限频**（2026-10-14 16:18 掉帧排查）：`outputLatency` / `ioBufferDuration`
    /// 不是内存里的缓存值，读一次要走音频系统查询。旧版挂在 10Hz 轮询上无条件测 →
    /// 每秒 10 次主线程查询常驻。
    ///
    /// 但这个量**只在输出路由变化时才变**（插拔耳机 / 连蓝牙 / 切 AirPlay），
    /// 所以改成三层：
    /// * 路由变化通知 → `force` 立即重测（响应性不降，见 `observeRouteChanges`）；
    /// * 换歌时 `force` 重测（起播那一刻歌词偏移最需要准）；
    /// * 平时每 2s 兜底一次（防漏通知 / 系统异常）。
    func refreshOutputLatency(force: Bool = false) {
        let now = Date().timeIntervalSinceReferenceDate
        guard force || now - lastLatencyMeasureAt >= 2 else { return }
        lastLatencyMeasureAt = now
        let session = AVAudioSession.sharedInstance()
        let measured = session.outputLatency + session.ioBufferDuration
        let clamped = measured.isFinite ? max(0, min(measured, 3)) : 0
        // 实时值：抖动 < 1ms 不写（内部计算零成本更新）
        if abs(clamped - liveLatency) > 0.001 {
            liveLatency = clamped
        }
        // UI 显示值：变化 ≥ 50ms 才发布（旧阈值 1ms 会让播放页每 2s 重算 → Menu 收起）
        if abs(clamped - outputLatency) > 0.05 {
            outputLatency = clamped
        }
    }

    /// 监听输出路由变化，立刻重测输出延迟。
    ///
    /// 这是「把轮询降频」的前提：降频有代价（可能滞后），用通知把这个代价抹掉。
    private func observeRouteChanges() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOutputLatency(force: true) }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var coreCancellable: AnyCancellable?
    private var lastTrackKeyOf: String?

    private var syncTimer: Timer?

    private init() {
        // ⚠️ 用 PlayerCore.restoredVolume()（含旧默认 0.7 → 1.0 的迁移）：
        // MPV 内核下 volume 是真软件音量，旧默认值会凭空把响度拉低 30%
        self.volume = PlayerCore.restoredVolume()
        // ⚠️ 不启动 `clock`：它是第二个 20Hz 时钟，与
        // `PlayerCore.currentTime` 数据完全重复，且活代码里已无人观察。
        // 详见 `PlayerClock` 的说明。这里保留调用以标注意图。
        self.clock.stop()

        // 定时同步 PlayerCore 状态（100ms 轮询以避免 KVO 复杂度）。
        //
        // 这个轮询是**必需**的：`PlayerService` 的 `currentTrack` / `lyrics` /
        // `queue` 等都靠它从 `PlayerCore` 搬运。但它每条 tick 都会重建
        // `ParsedLyrics`，因此不能更密。
        //
        // 注意：它只在**状态真的变化时**才写 `@Published`（每条都有 `!=` 比较），
        // 所以静止时不会引发视图重算。
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncFromCore()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        self.syncTimer = t

        // 输出路由变化 → 立刻重测输出延迟（把 10Hz 轮询降频的前提，见 refreshOutputLatency）
        observeRouteChanges()
    }

    // MARK: - Sync from PlayerCore

    /// 上一次搬运时用到的版本号（队列 / 歌词）。见各自 `@Published` 的 `didSet`。
    private var lastQueueRevision = -1
    private var lastLyricsRevision = -1

    private func syncFromCore() {
        let core = PlayerCore.shared

        // 输出延迟：走限频闸门（路由变化 / 换歌时 force，见 refreshOutputLatency）。
        // 切换输出设备（插拔耳机 / 连蓝牙 / 切 AirPlay）后会立刻重测，靠这里自动跟上。
        refreshOutputLatency()

        // isPlaying
        if isPlaying != core.isPlaying {
            isPlaying = core.isPlaying
        }

        // isBuffering / isLoading
        if isBuffering != core.isLoading {
            isBuffering = core.isLoading
        }

        // hasActiveTrack
        if hasCurrentTrack != core.hasActiveTrack {
            hasCurrentTrack = core.hasActiveTrack
        }

        // duration
        if duration != core.duration {
            duration = core.duration
        }

        // currentTrack + queue
        let coreItem = core.currentItem
        let coreQueue = core.queue

        // track 变化时更新（通过 keyOf 对比）
        if let item = coreItem {
            if lastTrackKeyOf != item.keyOf {
                lastTrackKeyOf = item.keyOf
                currentTrack = Track.from(musicItem: item)
                // 换歌 → 强制重测输出延迟（起播那一刻歌词偏移最需要准）
                refreshOutputLatency(force: true)
            }
        } else {
            if lastTrackKeyOf != nil || currentTrack != nil {
                lastTrackKeyOf = nil
                currentTrack = nil
            }
        }

        // queue 同步（★ 2026-10-14 16:18：用版本号闸门，只在队列真的变过时重建）
        //
        // 旧版**无条件** `coreQueue.map { Track.from(...) }` 之后再深比较：
        // `Track.from` 每首都要算三次 `keyOf` 字符串哈希（含两次字符串插值），
        // 队列 1000 首时单次数毫秒 —— 而这是 **10Hz 常驻**，主线程每 100ms 被占一块，
        // 表现就是「每个页面上下滑动都掉帧」。现在比对一次 Int 就结束。
        if lastQueueRevision != core.queueRevision {
            lastQueueRevision = core.queueRevision
            queue = coreQueue.map { Track.from(musicItem: $0) }
        }

        // currentIndex
        if let idx = core.currentIndex, idx != currentIndex {
            currentIndex = idx
        }

        // play mode -> repeatMode + shuffle
        let mode = AppState.shared.playMode
        switch mode {
        case 1:
            if repeatMode != .one { repeatMode = .one }
            if shuffleEnabled { shuffleEnabled = false }
        case 2:
            if repeatMode != .off { repeatMode = .off }
            if !shuffleEnabled { shuffleEnabled = true }
        default: // 0
            if repeatMode != .all { repeatMode = .all }
            if shuffleEnabled { shuffleEnabled = false }
        }

        // lyrics（★ 2026-10-14 16:18：用版本号闸门，只在歌词真的换了才重建）
        //
        // `ParsedLyrics.from` 是重活：逐字歌词下每行都要建一个 words 元组数组、
        // 把字符拼回整行，还要在 lrc 里线性找翻译（行×行）。旧版**每 100ms 重建一次
        // 再丢掉**，只有行数不同时才采用 —— 纯浪费。
        // 顺带修掉一个老毛病：以前「行数恰好相同」的新歌词会被静默丢弃，换歌后可能
        // 残留上一首的歌词；现在按版本号判断，换了一定会更新。
        let appState = AppState.shared
        if lastLyricsRevision != appState.lyricsRevision {
            lastLyricsRevision = appState.lyricsRevision
            let parsed = ParsedLyrics.from(lrc: appState.currentLrc,
                                           wordLyric: appState.currentWordLyric)
            lyrics = parsed.isEmpty ? nil : parsed
            lyricsCursor.updateLyrics(parsed)
        }

        // 更新歌词游标
        //
        // ⚠️ 时间源必须是 `PlayerCore.displayTime`，**不能**用 `clock.progress`。
        // `PlayerClock` 是第二个 20Hz 时钟，已停摆（见上文
        // `self.clock.stop()`），它的 `progress` 恒为 0，会让歌词高亮永远停在第一行。
        // `displayTime` 拖动时给 `scrubTime`、其余给真实播放时间，正是歌词需要的行为。
        let offset = AppState.shared.lyricOffset
        // ★ 再减去**输出延迟**：你耳朵听到的声音比播放器报告的位置晚 `outputLatency`，
        // 所以歌词要跟着晚一点显示才对得上（蓝牙耳机通常差 150–250ms，很显眼）。
        // 用户自己的偏移仍然照加/照减，作为额外微调。
        lyricsCursor.updateProgress(PlayerCore.shared.displayTime,
                                    offset: offset - liveLatency)
    }

    // MARK: - Control Actions

    func togglePlayPause() {
        PlayerCore.shared.togglePlayPause()
    }

    func play() {
        PlayerCore.shared.play()
    }

    func pause() {
        PlayerCore.shared.pause()
    }

    func seek(to time: TimeInterval) {
        PlayerCore.shared.seek(to: time)
    }

    func next() {
        PlayerCore.shared.next()
    }

    func previous() {
        PlayerCore.shared.previous()
    }

    func play(tracks: [Track], source: PlaySource = .none, startAt track: Track) {
        // 找到目标 Track 的索引
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else {
            return
        }
        // 将 Track 列表映射回 MusicItem（桥接层不保留原始引用，通过 id 反查或重建）
        let items = tracks.map { track -> MusicItem in
            if let existing = PlayerCore.shared.queue.first(where: {
                Track.from(musicItem: $0).id == track.id
            }) {
                return existing
            }
            let src = MusicSource(rawValue: track.sourcePlatform ?? "netease") ?? .netease
            return MusicItem(
                source: src,
                title: track.name,
                artist: track.artistNames,
                album: track.album.name,
                albumCoverURL: track.album.picUrl,
                duration: track.duration,
                qqSongMid: track.album.albumMid
            )
        }
        PlayerCore.shared.play(queue: items, startIndex: index)
    }

    func addToPlayNext(track: Track) {
        let item: MusicItem
        if let existing = PlayerCore.shared.queue.first(where: {
            Track.from(musicItem: $0).id == track.id
        }) {
            item = existing
        } else {
            let src = MusicSource(rawValue: track.sourcePlatform ?? "netease") ?? .netease
            item = MusicItem(
                source: src,
                title: track.name,
                artist: track.artistNames,
                album: track.album.name,
                albumCoverURL: track.album.picUrl,
                duration: track.duration,
                qqSongMid: track.album.albumMid
            )
        }

        let core = PlayerCore.shared
        if let idx = core.currentIndex {
            var newQueue = core.queue
            // 避免重复
            newQueue.removeAll { MusicItem.isSame($0, item) }
            newQueue.insert(item, at: idx + 1)
            core.queue = newQueue
        } else {
            core.queue = [item]
            core.currentIndex = 0
            core.playCurrentItem(seekTo: 0)
        }
    }

    func removeFromQueue(at index: Int) {
        PlayerCore.shared.removeFromQueue(at: IndexSet(integer: index))
    }

    func clearQueue() {
        PlayerCore.shared.queue = []
        PlayerCore.shared.currentIndex = nil
    }

    func cyclePlaybackMode() {
        let current = AppState.shared.playMode
        // 0 -> 1 -> 2 -> 0
        let next = (current + 1) % 3
        AppState.shared.playMode = next
    }
}

// MARK: - AVAudioSession helper
private extension AVAudioSession {
    static func activateIfNeeded() {
        AudioSessionManager.activate()
    }
}
