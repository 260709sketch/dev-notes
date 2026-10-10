import Foundation
import SwiftUI
import Combine
import AVFoundation

// MARK: - PlayerClock
/// 可观测的播放时钟，50ms 刷新，驱动进度条与歌词高亮。
@MainActor
final class PlayerClock: ObservableObject {
    @Published var progress: TimeInterval = 0

    private var timer: Timer?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 拖动中使用 scrubTime，否则使用 PlayerCore 的 currentTime
                let core = PlayerCore.shared
                if core.isScrubbing {
                    self.progress = core.scrubTime
                } else {
                    self.progress = core.currentTime
                }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
            // 桥接：通过 MPVolumeView 间接控制系统音量（此处简化为 UserDefaults 记录）
            UserDefaults.standard.set(volume, forKey: "player.volume")
        }
    }
    @Published var isMuted: Bool = false

    /// AMLL WebView 需要的实时播放时间（毫秒级精度，以秒为单位的 Double）
    var livePlaybackTime: TimeInterval {
        PlayerCore.shared.displayTime
    }

    private var cancellables = Set<AnyCancellable>()
    private var coreCancellable: AnyCancellable?
    private var lastTrackKeyOf: String?

    private var syncTimer: Timer?

    private init() {
        self.volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.7
        self.clock.start()

        // 定时同步 PlayerCore 状态（100ms 轮询以避免 KVO 复杂度）
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
        let offset = AppState.shared.lyricOffset
        lyricsCursor.updateProgress(clock.progress, offset: offset)
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
