import Foundation

/// 音乐来源平台
enum MusicSource: String, CaseIterable, Codable {
    case auto = "auto"
    case qq = "qq"
    case netease = "netease"
    case kugou = "kugou"
    case kuwo = "kuwo"

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .qq: return "QQ音乐"
        case .netease: return "网易云音乐"
        case .kugou: return "酷狗音乐"
        case .kuwo: return "酷我音乐"
        }
    }
}

/// 一首歌的统一模型（桥接原版 musicItem 语义）
struct MusicItem: Identifiable, Codable, Hashable {
    var id: String { keyOf }

    /// 唯一键：`{platform}://{id}_{artist}`，与原版 keyOf 一致
    var keyOf: String {
        let pid = platformId ?? title
        return "\(source.rawValue)://\(pid)_\(artist ?? "")"
    }

    var source: MusicSource
    var title: String
    var artist: String?
    var album: String?
    var albumCoverURL: String?
    var duration: TimeInterval

    // 各平台专属 ID（备用优先）
    var qqSongMid: String?
    var neteaseId: String?
    var kugouHash: String?
    var kuwoRid: String?

    /// 通用 id：不同平台用各自主 id
    var platformId: String? {
        switch source {
        case .qq: return qqSongMid
        case .netease: return neteaseId
        case .kugou: return kugouHash
        case .kuwo: return kuwoRid
        case .auto: return neteaseId ?? qqSongMid ?? kugouHash ?? kuwoRid
        }
    }

    /// 播放 URL（由各平台 resolve 后填充）
    var playURL: String?
    var localFilePath: String?

    var isLocalFile: Bool { localFilePath != nil }

    init(source: MusicSource,
         title: String,
         artist: String? = nil,
         album: String? = nil,
         albumCoverURL: String? = nil,
         duration: TimeInterval = 0,
         qqSongMid: String? = nil,
         neteaseId: String? = nil,
         kugouHash: String? = nil,
         kuwoRid: String? = nil,
         playURL: String? = nil,
         localFilePath: String? = nil) {
        self.source = source
        self.title = title
        self.artist = artist
        self.album = album
        self.albumCoverURL = albumCoverURL
        self.duration = duration
        self.qqSongMid = qqSongMid
        self.neteaseId = neteaseId
        self.kugouHash = kugouHash
        self.kuwoRid = kuwoRid
        self.playURL = playURL
        self.localFilePath = localFilePath
    }

    /// 判断是否为同一首歌（只比 id + 平台，与原版 isSameMediaItem 一致）
    static func isSame(_ a: MusicItem, _ b: MusicItem) -> Bool {
        (a.platformId ?? a.title) == (b.platformId ?? b.title) && a.source == b.source
    }
}

/// 一行逐行歌词（LRC，含翻译行支持）
struct LrcLine: Identifiable, Codable, Hashable {
    var id = UUID()
    var time: TimeInterval
    var text: String
    var translated: String?
}

/// 逐字歌词行（word-level，AMLL 风格）
struct WordLyricLine: Identifiable, Codable, Hashable {
    struct Word: Codable, Hashable {
        var char: String
        var start: TimeInterval
        var end: TimeInterval
    }
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var words: [Word]
}

/// 歌单
struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var coverURL: String?
    var tracks: [MusicItem] = []
    var createdAt: Date = Date()
}

/// 搜索歌单（平台返回）
struct RemotePlaylist: Identifiable, Codable, Hashable {
    var id: String { key }
    var key: String
    var source: MusicSource
    var name: String
    var coverURL: String?
    var trackCount: Int
    var creator: String?
}