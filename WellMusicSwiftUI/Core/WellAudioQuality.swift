import Foundation

/// 音质档位：取代原先的「高音质优先（无损）」布尔开关。
///
/// 各平台对档位的叫法不同，这里统一成一套线性档位，再在取链时映射到各平台自己的参数：
/// - 网易云 (`level`)：standard / higher / exhigh / lossless / hires
/// - QQ 音乐 (`filename` 前缀)：M500(128k) / M800(320k) / F000(FLAC) / RS01(Hi-Res)
/// - 酷狗 (`bitrate` / `quality`)：128 / 320 / flac / high
/// - 酷我 (`br` / `level`)：128k / 320k / flac / hires
/// - LX 自定义音源（`quality` 字符串）：128k / 320k / flac / flac24bit
enum WellAudioQuality: Int, CaseIterable, Identifiable, Codable {
    case standard = 0   // 标准 128k
    case high = 1       // 较高 320k
    case lossless = 2   // 无损 FLAC
    case hiRes = 3      // Hi-Res 母带

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "标准"
        case .high: return "较高"
        case .lossless: return "无损"
        case .hiRes: return "Hi-Res"
        }
    }

    /// 副标题：说明该档位的码率 / 格式，显示在设置页右侧
    var detail: String {
        switch self {
        case .standard: return "128 kbps"
        case .high: return "320 kbps"
        case .lossless: return "FLAC 无损"
        case .hiRes: return "24bit 母带"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: return "waveform"
        case .high: return "waveform.path"
        case .lossless: return "waveform.badge.magnifyingglass"
        case .hiRes: return "waveform.badge.plus"
        }
    }

    /// 播放器音质胶囊上的短标签（对应参考源码 `qualityDisplayName`）
    var badgeText: String {
        switch self {
        case .standard: return "128k"
        case .high: return "320k"
        case .lossless: return "FLAC"
        case .hiRes: return "Hi-Res"
        }
    }

    // MARK: 各平台映射

    /// 网易云 `level` 参数
    var neteaseLevel: String {
        switch self {
        case .standard: return "standard"
        case .high: return "exhigh"
        case .lossless: return "lossless"
        case .hiRes: return "hires"
        }
    }

    /// 档位降级链：用户选的档位 → `standard`。
    ///
    /// **云盘上传的文件没有高档位音源**（用户传的多是 128k/320k），按用户选的
    /// 无损 / Hi-Res 档位去要地址，服务端只会回一个 `url: null` —— 表现就是
    /// 「云盘歌曲点了不播」。参考实现在拿到空地址时会改用 `standard` 再要一次，
    /// 这里把这条降级链固化下来（只降一级，不做全档遍历，避免失败路径多发请求）。
    var neteaseLevelLadder: [String] {
        self == .standard ? ["standard"] : [neteaseLevel, "standard"]
    }

    /// 网易云老接口 `api/song/enhance/player/url` 的 `br` 参数（码率，不是档位名）。
    ///
    /// 该接口按码率取地址、不区分档位，云盘上传文件走它命中率最高。
    var neteaseBitrate: Int {
        switch self {
        case .standard: return 128000
        case .high: return 320000
        case .lossless, .hiRes: return 999000
        }
    }

    /// 码率降级链（同 `neteaseLevelLadder` 的理由）。
    var neteaseBitrateLadder: [Int] {
        self == .standard ? [128000] : [neteaseBitrate, 128000]
    }

    /// QQ 音乐 filename 前缀
    var qqFilePrefix: String {
        switch self {
        case .standard: return "M500"
        case .high: return "M800"
        case .lossless: return "F000"
        case .hiRes: return "RS01"
        }
    }

    /// 酷狗 bitrate（128 / 320 / flac / high）
    var kugouBitrate: String {
        switch self {
        case .standard: return "128"
        case .high: return "320"
        case .lossless: return "flac"
        case .hiRes: return "high"
        }
    }

    /// 酷我 br（128k / 320k / flac / hires）
    var kuwoBr: String {
        switch self {
        case .standard: return "128k"
        case .high: return "320k"
        case .lossless: return "flac"
        case .hiRes: return "hires"
        }
    }

    /// LX 自定义音源 quality 字符串
    var lxQuality: String {
        switch self {
        case .standard: return "128k"
        case .high: return "320k"
        case .lossless: return "flac"
        case .hiRes: return "flac24bit"
        }
    }

    /// 兼容旧布尔语义：非标准档即视为高音质
    var isHighQuality: Bool { self != .standard }
}
