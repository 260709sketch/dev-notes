import Foundation

// MARK: - 搜索平台 / 模块

/// 搜索页可切换的平台（网易云 / QQ音乐 / 酷狗）
enum WellSearchPlatform: String, CaseIterable, Identifiable {
    case netease = "网易云"
    case qq = "QQ音乐"
    case kugou = "酷狗"

    var id: String { rawValue }

    var source: MusicSource {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        }
    }
}

/// 搜索页的结果分类模块
enum WellSearchType: String, CaseIterable, Identifiable {
    case all = "综合"
    case songs = "单曲"
    case artists = "歌手"
    case albums = "专辑"
    case playlists = "歌单"

    var id: String { rawValue }
}

// MARK: - 摘要模型

/// 搜索结果里的歌手条目（跨平台统一模型）。
struct WellArtistSummary: Identifiable, Hashable {
    var id: String
    var name: String
    var picURL: String?
    var platform: MusicSource
    /// 平台原生 mid（QQ / 酷狗跳转需要）
    var mid: String?
    /// 副标题（如歌曲数），用于卡片下方说明
    var subtitle: String?
}

/// 搜索结果里的专辑条目。
struct WellAlbumSummary: Identifiable, Hashable {
    var id: String
    var name: String
    var picURL: String?
    var artistName: String
    var platform: MusicSource
    /// QQ / 酷狗专辑 mid（部分接口需要）
    var albumMid: String?
    /// 专辑类型（「专辑 / EP / 单曲」；歌手专辑接口返回）。nil 视作「专辑」。
    ///
    /// ⚠️ 网易云该字段**中英混合**：「专辑」是中文，「Single / EP」是英文
    /// （实测周杰伦《即兴曲》type="Single"）。
    var albumType: String?
    /// 发行时间（**毫秒**时间戳；歌手专辑接口返回，搜索接口缺省时为 nil）
    var publishTime: Int?

    /// 是否 EP / 单曲（歌手主页分货架用）。
    ///
    /// ⚠️ 必须同时匹配英文：网易云 `type` 可能是「Single / EP」（英文），
    /// 早期只匹配「单曲」把 16 首 Single 错划进了专辑货架（2026-10-14 修复）。
    var isEPOrSingle: Bool {
        guard let albumType else { return false }
        let t = albumType.lowercased()
        return t.contains("ep") || t.contains("单曲") || t.contains("single")
    }

    /// 专辑类型的中文展示（「专辑 / EP / 单曲」）。
    var albumTypeText: String {
        guard let albumType else { return "专辑" }
        let t = albumType.lowercased()
        if t.contains("ep") { return "EP" }
        if t.contains("single") || t.contains("单曲") { return "单曲" }
        return "专辑"
    }

    /// 中文发行日期（「2025年6月5日」）；`publishTime` 缺失或 <= 0 时为 nil。
    var publishDateText: String? {
        guard let publishTime, publishTime > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(publishTime) / 1000)
        return Self.publishDateFormatter.string(from: date)
    }

    private static let publishDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}

/// 搜索结果里的歌单条目。
struct WellPlaylistSummary: Identifiable, Hashable {
    var id: String
    var name: String
    var coverURL: String?
    var playCount: Int
    var trackCount: Int
    var creatorName: String?
    /// 歌单所属平台（搜索页 QQ / 酷狗歌单打开时需要区分通道）。
    var platform: MusicSource = .netease
}

/// 排行榜条目（发现页「排行榜」货架用）。
///
/// 与普通歌单的区别是多一个 `updateFrequency`（如「每周更新」）——
/// 卡片右下角会把它压在渐变遮罩上，所以单独成模型而不是复用 `WellPlaylistSummary`。
struct WellToplistSummary: Identifiable, Hashable {
    var id: String
    var name: String
    var coverURL: String?
    var updateFrequency: String?
}

/// 一次聚合搜索的结果集合。
struct WellSearchResult {
    var songs: [MusicItem] = []
    var artists: [WellArtistSummary] = []
    var albums: [WellAlbumSummary] = []
    var playlists: [WellPlaylistSummary] = []

    /// 某模块是否为空（综合模块需四类全空才算空）
    func isEmpty(for type: WellSearchType) -> Bool {
        switch type {
        case .all: return songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
        case .songs: return songs.isEmpty
        case .artists: return artists.isEmpty
        case .albums: return albums.isEmpty
        case .playlists: return playlists.isEmpty
        }
    }
}

// MARK: - 详情来源

/// 点击搜索卡片后要展开的详情目标。
///
/// ⚠️ QQ / 酷狗的详情接口要的是**平台原生 mid**（QQ 专辑 `albummid`、QQ 歌手
/// `singermid`），不是搜索结果里的数字 id —— 传错会把「按名搜索」的兜底结果
/// 当成详情展示（用户实测：「专辑进入之后不是这张专辑的歌」）。所以这里
/// 专门带上 `mid`；网易云只有数字 id，`mid` 传 nil 即可。
enum WellSearchDetailSource: Hashable {
    case playlist(id: String, platform: MusicSource, name: String)
    case album(id: String, platform: MusicSource, name: String, artist: String, mid: String?)
    case artist(id: String, platform: MusicSource, name: String, mid: String?)

    var title: String {
        switch self {
        case .playlist(_, _, let name): return name
        case .album(_, _, let name, _, _): return name
        case .artist(_, _, let name, _): return name
        }
    }

    var platform: MusicSource {
        switch self {
        case .playlist(_, let p, _): return p
        case .album(_, let p, _, _, _): return p
        case .artist(_, let p, _, _): return p
        }
    }
}

// MARK: - 展示辅助

extension WellPlaylistSummary {
    /// 「1234.5万」风格的播放量文案
    var playCountText: String {
        guard playCount > 0 else { return "" }
        if playCount >= 100_000_000 { return String(format: "%.1f亿", Double(playCount) / 100_000_000) }
        if playCount >= 10_000 { return String(format: "%.1f万", Double(playCount) / 10_000) }
        return "\(playCount)"
    }
}

extension MusicItem {
    /// 「mm:ss」时长文案
    var durationText: String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}