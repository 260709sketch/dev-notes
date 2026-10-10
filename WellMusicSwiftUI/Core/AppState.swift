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

    /// 歌词来源：auto/qq/netease/kugou/kuwo
    @Published var lyricSource: MusicSource {
        didSet { defaults.set(lyricSource.rawValue, forKey: "music.lyricSource") }
    }

    /// 是否启用逐字歌词（karaoke）
    @Published var karaokeEnabled: Bool {
        didSet { defaults.set(karaokeEnabled, forKey: "lyric.karaokeEnabled") }
    }

    /// 歌词同步偏移（秒）：正值=高亮提前，负值=高亮延后
    /// 用于校准歌词与歌声的残余偏差（耳机/扬声器输出延迟等）
    @Published var lyricOffset: TimeInterval {
        didSet { defaults.set(lyricOffset, forKey: "lyric.offset") }
    }

    /// 播放模式：0 列表循环 / 1 单曲循环 / 2 随机
    @Published var playMode: Int {
        didSet { defaults.set(playMode, forKey: "player.playMode") }
    }

    /// 高音质优先（无损）
    @Published var highQuality: Bool {
        didSet { defaults.set(highQuality, forKey: "player.highQuality") }
    }

    /// 录音式逐字播放（原 lyric.karaoke 衍生选项）
    @Published var crossfade: Bool {
        didSet { defaults.set(crossfade, forKey: "player.crossfade") }
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
    @Published var currentLrc: [LrcLine] = []
    /// 当前逐字歌词（存在即优先渲染）
    @Published var currentWordLyric: [WordLyricLine] = []

    private init() {
        let src = defaults.string(forKey: "music.lyricSource") ?? "auto"
        lyricSource = MusicSource(rawValue: src) ?? .auto
        karaokeEnabled = defaults.object(forKey: "lyric.karaokeEnabled") == nil
            ? true : defaults.bool(forKey: "lyric.karaokeEnabled")
        lyricOffset = defaults.object(forKey: "lyric.offset") == nil
            ? 0 : defaults.double(forKey: "lyric.offset")
        playMode = defaults.object(forKey: "player.playMode") == nil
            ? 0 : defaults.integer(forKey: "player.playMode")
        highQuality = defaults.object(forKey: "player.highQuality") == nil
            ? true : defaults.bool(forKey: "player.highQuality")
        crossfade = defaults.object(forKey: "player.crossfade") == nil
            ? false : defaults.bool(forKey: "player.crossfade")

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

    // MARK: 歌词来源切换（原「下一首歌生效」语义统一由取词时读取本值）

    func setLyricSource(_ source: MusicSource) {
        lyricSource = source
    }
}