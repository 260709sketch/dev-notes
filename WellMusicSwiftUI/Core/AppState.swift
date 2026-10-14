import Foundation
import Combine

/// 全局应用状态（替代原 Zustand store + MMKV 持久化）
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private let defaults = UserDefaults.standard
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    // MARK: 设置项（持久化）

    /// 歌词同步偏移（秒）：正值=高亮提前，负值=高亮延后
    /// 用于校准歌词与歌声的残余偏差（耳机/扬声器输出延迟等）。
    /// 设置页已移除，改由播放器界面的「歌词偏移」菜单调节。
    @Published var lyricOffset: TimeInterval {
        didSet { defaults.set(lyricOffset, forKey: "lyric.offset") }
    }

    /// 播放模式：0 列表循环 / 1 单曲循环 / 2 随机
    /// 设置页已移除，改由播放器界面的「播放模式」菜单调节。
    @Published var playMode: Int {
        didSet { defaults.set(playMode, forKey: "player.playMode") }
    }

    /// 音质档位（取代原「高音质优先（无损）」布尔开关）
    @Published var audioQuality: WellAudioQuality {
        didSet { defaults.set(audioQuality.rawValue, forKey: "player.audioQuality") }
    }

    // MARK: 运行态（可持久化的收藏/历史/歌单）

    /// 我收藏的歌曲
    @Published var favoriteTracks: [MusicItem] = [] {
        didSet { persistJSON(favoriteTracks, key: "favorites.tracks") }
    }
    /// 收藏的歌单（云端歌单）
    @Published var favoritePlaylists: [RemotePlaylist] = [] {
        didSet { persistJSON(favoritePlaylists, key: "favorites.playlists") }
    }
    /// 播放历史
    @Published var playHistory: [MusicItem] = [] {
        didSet { persistJSON(playHistory, key: "favorites.history") }
    }
    /// 自建歌单
    @Published var playlists: [Playlist] = [] {
        didSet { persistJSON(playlists, key: "playlists.all") }
    }
    /// 下载中的任务
    @Published var downloadTasks: [String: Double] = [:]

    // MARK: 运行态（不持久化）

    /// 当前歌曲（播放内核维护，此处在 UI 侧映射）
    @Published var currentTrack: MusicItem?
    /// 当前逐行歌词
    @Published var currentLrc: [LrcLine] = [] {
        didSet { lyricsRevision &+= 1 }
    }
    /// 当前逐字歌词（存在即优先渲染）
    @Published var currentWordLyric: [WordLyricLine] = [] {
        didSet { lyricsRevision &+= 1 }
    }

    /// 歌词版本号：`currentLrc` / `currentWordLyric` 任一被写入就 +1。
    ///
    /// 用途（2026-10-14 16:18 掉帧排查）：`PlayerService.syncFromCore()` 原先每 100ms
    /// **无条件**重建一次 `ParsedLyrics`（逐字歌词下要建上千个 (字符,起,止) 元组、
    /// 逐行拼回整行、还在 lrc 里线性找翻译 = 行×行），重建完却只在行数变化时才采用。
    /// 改成版本号闸门后，只在歌词真的换了一首时才做这件事。
    private(set) var lyricsRevision: Int = 0

    private init() {
        lyricOffset = defaults.object(forKey: "lyric.offset") == nil
            ? 0 : defaults.double(forKey: "lyric.offset")
        playMode = defaults.object(forKey: "player.playMode") == nil
            ? 0 : defaults.integer(forKey: "player.playMode")
        // 音质：新键优先；旧安装若开过高音质开关，迁移成「较高」档，否则标准档
        if let raw = defaults.object(forKey: "player.audioQuality") as? Int,
           let quality = WellAudioQuality(rawValue: raw) {
            audioQuality = quality
        } else if defaults.bool(forKey: "player.highQuality") {
            audioQuality = .high
        } else {
            audioQuality = .standard
        }

        favoriteTracks = loadJSON([MusicItem].self, key: "favorites.tracks") ?? []
        favoritePlaylists = loadJSON([RemotePlaylist].self, key: "favorites.playlists") ?? []
        playHistory = loadJSON([MusicItem].self, key: "favorites.history") ?? []
        playlists = loadJSON([Playlist].self, key: "playlists.all") ?? []
    }

    // MARK: 持久化工具

    private func persistJSON<T: Encodable>(_ value: T, key: String) {
        guard let data = try? jsonEncoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? jsonDecoder.decode(type, from: data)
    }

    // MARK: 收藏操作

    func isFavorite(_ track: MusicItem) -> Bool {
        favoriteTracks.contains { MusicItem.isSame($0, track) }
    }

    func toggleFavorite(_ track: MusicItem) {
        if isFavorite(track) {
            favoriteTracks.removeAll { MusicItem.isSame($0, track) }
        } else {
            favoriteTracks.insert(track, at: 0)
        }
    }

    /// 记录播放历史（去重，最新在前，上限 500）
    func recordHistory(_ track: MusicItem) {
        playHistory.removeAll { MusicItem.isSame($0, track) }
        playHistory.insert(track, at: 0)
        if playHistory.count > 500 { playHistory = Array(playHistory.prefix(500)) }
    }
}