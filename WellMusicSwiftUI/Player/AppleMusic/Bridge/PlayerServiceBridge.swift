import Foundation
import SwiftUI
import Combine
import AVFoundation

// MARK: - PlayerClock
/// 可观测的播放时钟。
///
/// ⚠️ **默认不启动**（见 `PlayerService.init` 的说明）。
///
/// 这个类型来自 Kumone 的移植，它用一个 20Hz（50ms）的 `Timer` + `Task { @MainActor }`
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
        guard !lyrics.lines.isEmpty else { activeIndex = nil; return }
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
@MainActor
final class SleepTimer: ObservableObject {
    struct State {
        var isActive: Bool = false
        var fireDate: Date?
        var endOfTrackMode: Bool = false
    }

    @Published var state = State()

    private var timer: Timer?
    private var endObserver: NSObjectProtocol?

    func schedule(afterMinutes minutes: Int) {
        cancel()
        state.isActive = true
        state.endOfTrackMode = false
        state.fireDate = Date().addingTimeInterval(TimeInterval(minutes) * 60)

        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes) * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireSleep()
            }
        }
    }

    func scheduleAtEndOfCurrentTrack() {
        cancel()
        state.isActive = true
        state.endOfTrackMode = true
        state.fireDate = nil

        // 监听 AVPlayer 播放结束
        // 此处通过 PlayerCore 的 end 间接触发；简化实现：使用 duration - currentTime
        let core = PlayerCore.shared
        let remaining = max(0, core.duration - core.currentTime)
        state.fireDate = Date().addingTimeInterval(remaining)

        timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireSleep()
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        state = State()
    }

    private func fireSleep() {
        PlayerCore.shared.pause()
        cancel()
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
    @Published private(set) var outputLatency: TimeInterval = 0

    /// 重新测量输出延迟。由 0.1s 同步 tick 调用（一次属性读，很便宜）。
    func refreshOutputLatency() {
        let session = AVAudioSession.sharedInstance()
        let measured = session.outputLatency + session.ioBufferDuration
        let clamped = measured.isFinite ? max(0, min(measured, 3)) : 0
        // 抖动 < 1ms 不写 @Published，避免无谓的视图重算
        if abs(clamped - outputLatency) > 0.001 {
            outputLatency = clamped
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var coreCancellable: AnyCancellable?
    private var lastTrackKeyOf: String?

    private var syncTimer: Timer?

    private init() {
        self.volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.7
        // ⚠️ 不启动 `clock`：它是 Kumone 带来的第二个 20Hz 时钟，与
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
    }

    // MARK: - Sync from PlayerCore

    private func syncFromCore() {
        let core = PlayerCore.shared

        // 输出延迟：每 tick 重新测量（属性读很便宜，只在变化 >1ms 时才写 @Published）。
        // 切换输出设备（插拔耳机 / 连蓝牙 / 切 AirPlay）后值会变，靠这里自动跟上。
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
            }
        } else {
            if lastTrackKeyOf != nil || currentTrack != nil {
                lastTrackKeyOf = nil
                currentTrack = nil
            }
        }

        // queue 同步
        let newQueue = coreQueue.map { Track.from(musicItem: $0) }
        if queue != newQueue {
            queue = newQueue
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

        // lyrics
        let lrc = AppState.shared.currentLrc
        let wordLyric = AppState.shared.currentWordLyric
        let parsed = ParsedLyrics.from(lrc: lrc, wordLyric: wordLyric)
        if lyrics?.lines.count != parsed.lines.count {
            lyrics = parsed.isEmpty ? nil : parsed
            lyricsCursor.updateLyrics(parsed)
        }

        // 更新歌词游标
        //
        // ⚠️ 时间源必须是 `PlayerCore.displayTime`，**不能**用 `clock.progress`。
        // `PlayerClock` 是 Kumone 带进来的第二个 20Hz 时钟，已停摆（见上文
        // `self.clock.stop()`），它的 `progress` 恒为 0，会让歌词高亮永远停在第一行。
        // `displayTime` 拖动时给 `scrubTime`、其余给真实播放时间，正是歌词需要的行为。
        let offset = AppState.shared.lyricOffset
        // ★ 再减去**输出延迟**：你耳朵听到的声音比播放器报告的位置晚 `outputLatency`，
        // 所以歌词要跟着晚一点显示才对得上（蓝牙耳机通常差 150–250ms，很显眼）。
        // 用户自己的偏移仍然照加/照减，作为额外微调。
        lyricsCursor.updateProgress(PlayerCore.shared.displayTime,
                                    offset: offset - outputLatency)
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
