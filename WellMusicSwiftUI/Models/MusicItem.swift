import Foundation

/// 音乐来源平台
enum MusicSource: String, CaseIterable, Codable {
    case auto = "auto"
    case qq = "qq"
    case netease = "netease"
    case kugou = "kugou"
    case kuwo = "kuwo"
    /// 自定义音源（LX 脚本）返回的歌曲：`neteaseId` 存放带平台前缀的 songmid
    case lx = "lx"

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .qq: return "QQ音乐"
        case .netease: return "网易云音乐"
        case .kugou: return "酷狗音乐"
        case .kuwo: return "酷我音乐"
        case .lx: return "自定义音源"
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

    /// 平台侧「需付费 / VIP」标记（网易云 `fee`、QQ `pay`、酷狗 `privilege`）。
    /// 仅供列表行显示 VIP 小徽章，不参与任何播放鉴权逻辑。
    var isVip: Bool = false

    // 各平台专属 ID（备用优先）
    var qqSongMid: String?
    /// QQ 音乐 file.media_mid（部分 vkey 接口需要，缺省时回退 songmid）
    var qqMediaMid: String?
    /// QQ 音乐所属专辑的 albummid（跳转专辑详情用；注意 ≠ qqSongMid 歌曲自身 mid）
    var qqAlbumMid: String?
    var neteaseId: String?
    var kugouHash: String?
    var kuwoRid: String?
    /// 所属专辑的平台 id（网易云数字 id / 酷狗 AlbumID / QQ albummid）。
    /// 播放页跳专辑详情用它 —— 缺失时会退化成哈希假 id，导致进错专辑。
    var platformAlbumId: String?

    /// 网易云云盘歌曲标记（`/api/v1/cloud/get` 条目，用户 2026-10-15）。
    ///
    /// 云盘上传歌的 id 只在账号云盘里有效、公共曲库查不到，LX 自定义音源与
    /// 内置音源都解析不到它；播放时必须**直走网易云官方通道**
    /// （见 `MusicURLResolver` 的云盘分支），否则表现为「云盘歌曲不能播放」。
    var isCloudDisk: Bool = false

    /// 通用 id：不同平台用各自主 id
    var platformId: String? {
        switch source {
        case .qq: return qqSongMid
        case .netease: return neteaseId
        case .kugou: return kugouHash
        case .kuwo: return kuwoRid
        case .lx: return neteaseId
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
         isVip: Bool = false,
        qqSongMid: String? = nil,
        qqMediaMid: String? = nil,
        qqAlbumMid: String? = nil,
         neteaseId: String? = nil,
         kugouHash: String? = nil,
         kuwoRid: String? = nil,
         platformAlbumId: String? = nil,
         playURL: String? = nil,
         localFilePath: String? = nil,
         isCloudDisk: Bool = false) {
        self.source = source
        self.title = title
        self.artist = artist
        self.album = album
        self.albumCoverURL = albumCoverURL
        self.duration = duration
        self.isVip = isVip
        self.qqSongMid = qqSongMid
        self.qqMediaMid = qqMediaMid
        self.qqAlbumMid = qqAlbumMid
        self.neteaseId = neteaseId
        self.kugouHash = kugouHash
        self.kuwoRid = kuwoRid
        self.platformAlbumId = platformAlbumId
        self.playURL = playURL
        self.localFilePath = localFilePath
        self.isCloudDisk = isCloudDisk
    }

    // MARK: Codable

    /// 自定义解码：**所有字段容错**（缺键用默认值，不让整条记录解码失败）。
    ///
    /// ⚠️ 之所以不能依赖合成 init(from:)：Swift 的合成解码对缺失的非可选键
    /// 直接抛错，而收藏/历史是**跨版本持久化**的数据 —— 以后每加一个字段
    /// （如 `isCloudDisk`），旧安装升级后会整条记录解不出来，表现为
    /// 「收藏的歌莫名其妙少了一批」。这里统一 decodeIfPresent + 默认值。
    private enum CodingKeys: String, CodingKey {
        case source, title, artist, album, albumCoverURL, duration, isVip
        case qqSongMid, qqMediaMid, qqAlbumMid, neteaseId, kugouHash, kuwoRid
        case platformAlbumId, playURL, localFilePath, isCloudDisk
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(MusicSource.self, forKey: .source)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        albumCoverURL = try c.decodeIfPresent(String.self, forKey: .albumCoverURL)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        isVip = try c.decodeIfPresent(Bool.self, forKey: .isVip) ?? false
        qqSongMid = try c.decodeIfPresent(String.self, forKey: .qqSongMid)
        qqMediaMid = try c.decodeIfPresent(String.self, forKey: .qqMediaMid)
        qqAlbumMid = try c.decodeIfPresent(String.self, forKey: .qqAlbumMid)
        neteaseId = try c.decodeIfPresent(String.self, forKey: .neteaseId)
        kugouHash = try c.decodeIfPresent(String.self, forKey: .kugouHash)
        kuwoRid = try c.decodeIfPresent(String.self, forKey: .kuwoRid)
        platformAlbumId = try c.decodeIfPresent(String.self, forKey: .platformAlbumId)
        playURL = try c.decodeIfPresent(String.self, forKey: .playURL)
        localFilePath = try c.decodeIfPresent(String.self, forKey: .localFilePath)
        isCloudDisk = try c.decodeIfPresent(Bool.self, forKey: .isCloudDisk) ?? false
    }

    /// 判断是否为同一首歌（只比 id + 平台，与原版 isSameMediaItem 一致）
    static func isSame(_ a: MusicItem, _ b: MusicItem) -> Bool {
        (a.platformId ?? a.title) == (b.platformId ?? b.title) && a.source == b.source
    }
}

extension MusicItem {
    /// 把「自定义音源」条目（`neteaseId` 存带前缀 songmid）还原成对应平台的普通条目，
    /// 便于歌词、播放等既有链路按平台处理。
    func unwrappedFromCustomSource() -> MusicItem {
        guard source == .lx else { return self }
        let parsed = WellLXProtocol.parseLxPlatform(neteaseId ?? title)
        var item = self
        item.source = WellLXProtocol.platformSource(forLxSource: parsed.source)
        item.qqSongMid = nil
        item.neteaseId = nil
        item.kugouHash = nil
        item.kuwoRid = nil
        switch parsed.source {
        case "wy": item.neteaseId = parsed.cleanId
        case "kg": item.kugouHash = parsed.cleanId
        case "kw": item.kuwoRid = parsed.cleanId
        default: item.qqSongMid = parsed.cleanId
        }
        return item
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