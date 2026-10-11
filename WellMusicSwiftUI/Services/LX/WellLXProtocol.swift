import Foundation

/// 一个 LX 音源脚本的元信息（对照 wellmusic lxMusicSourceAdapter 的 INFO_NAMES）
struct WellLXScriptInfo: Codable, Hashable, Identifiable {
    /// 稳定 ID：name+version+author 的 md5 前 12 位，用于持久化与去重
    var id: String
    var name: String
    var description: String
    var author: String
    var homepage: String
    var version: String
    /// 从脚本头部声明的 srcUrl（用于在线更新，可为空）
    var srcUrl: String
    /// 脚本原文（持久化保存，启动时无需重新导入）
    var script: String
    var scriptType: String = "lxmusic"
    /// 是否启用（master 开关之外的单源开关）
    var isEnabled: Bool = true
}

/// LX 脚本搜索结果（脚本返回的歌曲条目）
struct WellLXSongResult: Identifiable, Hashable {
    var id: String { songmid }
    /// 带平台前缀的 ID，例如 netease_123 / kugou_hash，直接用于播放解析
    var songmid: String
    var title: String
    var artist: String
    var interval: TimeInterval? = nil
    var album: String? = nil
    var cover: String? = nil
}

enum WellLXError: LocalizedError {
    case notLxScript
    case duplicated
    case notLoaded(String)
    case scriptError(String)
    case timeout(String)
    case noSource
    case resolveFailed

    var errorDescription: String? {
        switch self {
        case .notLxScript: return "不是有效的 LX 音源脚本"
        case .duplicated: return "该音源已存在"
        case .notLoaded(let n): return "音源「\(n)」尚未加载"
        case .scriptError(let m): return "音源脚本执行出错：\(m)"
        case .timeout(let n): return "音源「\(n)」请求超时"
        case .noSource: return "没有可用的 LX 音源"
        case .resolveFailed: return "所有 LX 音源都未能解析播放地址"
        }
    }
}

/// LX 音源协议层（对照 wellmusic src/helpers/userApi/lxMusicSourceAdapter.ts）
/// 负责：脚本格式检测、元信息解析、平台前缀解析、请求 payload 构建、响应宽容解析
enum WellLXProtocol {

    // MARK: 脚本格式检测

    /// 判断一段源码是否为 LX 自定义音源脚本
    /// 规则（与 wellmusic 一致）：头部注释 + 出现 LX API 特征 + 不含 Well 自有格式
    static func isLxMusicScript(_ script: String) -> Bool {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasHeaderComment(trimmed) else { return false }
        let hasLxApi =
            regex(trimmed, #"\bEVENT_NAMES\b"#) != nil ||
            regex(trimmed, #"\blx\s*\.\s*(on|send)\b"#) != nil ||
            regex(trimmed, #"\blxu?\s*\.\s*(on|send|request|EVENT_NAMES)\b"#) != nil ||
            regex(trimmed, #"\bglobalThis\s*\.\s*lx"#) != nil
        let isWellFormat = regex(trimmed, #"module\s*\.\s*exports\s*\.\s*getMusicUrl"#) != nil
        return hasLxApi && !isWellFormat
    }

    private static func hasHeaderComment(_ script: String) -> Bool {
        regex(script, #"^/\*[\s\S]+?\*/"#) != nil
    }

    private static func regex(_ text: String, _ pattern: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern).firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    // MARK: 元信息解析

    private static let infoLimits: [(String, Int)] = [
        ("name", 24), ("description", 256), ("author", 56),
        ("homepage", 1024), ("version", 36),
    ]

    /// 从头部注释解析 @name/@version/@author/@description/@homepage，带长度限制
    static func parseScriptInfo(_ script: String, scriptRef: String = "") -> WellLXScriptInfo {
        var infos: [String: String] = [:]
        if let match = regex(script.trimmingCharacters(in: .whitespacesAndNewlines), #"^/\*[\s\S]+?\*/"#),
           let range = Range(match.range, in: script) {
            let header = String(script[range])
            let linePattern = #"^\s?\*\s?@(\w+)\s(.+)$"#
            for line in header.components(separatedBy: CharacterSet.newlines) {
                guard let m = regex(line, linePattern),
                      let keyRange = Range(m.range(at: 1), in: line),
                      let valRange = Range(m.range(at: 2), in: line) else { continue }
                let key = String(line[keyRange])
                if infoLimits.contains(where: { $0.0 == key }) {
                    infos[key] = String(line[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        for (key, maxLen) in infoLimits {
            var value = infos[key] ?? ""
            if value.count > maxLen { value = String(value.prefix(maxLen)) + "..." }
            infos[key] = value
        }
        return WellLXScriptInfo(
            id: stableID(name: infos["name"] ?? "", version: infos["version"] ?? "", author: infos["author"] ?? ""),
            name: infos["name"] ?? "未命名音源",
            description: infos["description"] ?? "",
            author: infos["author"] ?? "",
            homepage: infos["homepage"] ?? "",
            version: infos["version"] ?? "1.0.0",
            srcUrl: extractSrcUrl(from: script) ?? scriptRef,
            script: script
        )
    }

    static func stableID(name: String, version: String, author: String) -> String {
        let key = "\(name)|\(version)|\(author)"
        let digest = CryptoUtils.md5Data(Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// 提取脚本内声明的 srcUrl（在线更新地址）
    static func extractSrcUrl(from script: String) -> String? {
        guard let m = regex(script, #"srcUrl\s*[:=]\s*['"`]([^'"`]+)['"`]"#),
              let r = Range(m.range(at: 1), in: script) else { return nil }
        return String(script[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 平台前缀解析

    /// 将带前缀的 songmid 解析成 lx 平台标识 + 纯净 ID
    /// netease_/wy_ → wy；kugou_/kg_ → kg；kuwo_/kw_ → kw；migu_/mg_ → mg；其余 → tx
    static func parseLxPlatform(_ songmid: String) -> (source: String, cleanId: String) {
        let raw = songmid
        func strip(_ prefix: String) -> String { String(raw.dropFirst(prefix.count)) }
        if raw.hasPrefix("netease_") { return ("wy", strip("netease_")) }
        if raw.hasPrefix("wy_") { return ("wy", strip("wy_")) }
        if raw.hasPrefix("kugou_") { return ("kg", strip("kugou_")) }
        if raw.hasPrefix("kg_") { return ("kg", strip("kg_")) }
        if raw.hasPrefix("kuwo_") { return ("kw", strip("kuwo_")) }
        if raw.hasPrefix("kw_") { return ("kw", strip("kw_")) }
        if raw.hasPrefix("migu_") { return ("mg", strip("migu_")) }
        if raw.hasPrefix("mg_") { return ("mg", strip("mg_")) }
        return ("tx", raw)
    }

    /// lx 平台标识 → 应用内 MusicSource
    static func platformSource(forLxSource source: String) -> MusicSource {
        switch source {
        case "wy": return .netease
        case "kg": return .kugou
        case "kw": return .kuwo
        default: return .qq // tx / mg 等统一落 QQ（播放解析直接用 lxSongID，不影响）
        }
    }

    // MARK: payload 构建（对照 wellmusic getMusicUrlViaScript / searchMusicViaScript）

    /// musicUrl 请求：info.musicInfo 携带歌曲元数据 + 音质
    static func makeMusicUrlPayload(songmid: String, title: String, artist: String,
                                    quality: String, requestKey: String) -> [String: Any] {
        let p = parseLxPlatform(songmid)
        return [
            "action": "musicUrl",
            "source": p.source,
            "info": [
                "musicInfo": [
                    "id": p.cleanId,
                    "songmid": p.cleanId,
                    "title": title,
                    "name": title,
                    "singer": artist,
                    "artist": artist,
                    "source": p.source,
                    "hash": p.cleanId,
                    "albumName": "",
                    "albumId": "",
                    "interval": NSNull(),
                    "types": [],
                    "typeUrl": [:],
                    "_quality": quality,
                ],
                "requestContext": ["requestKey": requestKey, "requestType": "current"],
                "quality": quality,
                "type": quality,
            ],
        ]
    }

    /// musicSearch 请求
    /// 注意：preload 的 handleRequest 只透传 `data.info`（见 user-api-preload.js），
    /// 因此搜索参数必须放在 info 字段内（wellmusic adapter 原版误用 data 字段导致脚本收不到参数）
    static func makeSearchPayload(keyword: String, page: Int, pageSize: Int,
                                  source: String, requestKey: String) -> [String: Any] {
        [
            "action": "musicSearch",
            "source": source,
            "info": [
                "key": keyword,
                "page": page,
                "pageSize": pageSize,
                "type": "song",
                "requestContext": ["requestKey": requestKey, "requestType": "current"],
            ],
        ]
    }

    /// musicLyric 请求（lx5 歌词并入用）
    static func makeLyricPayload(songmid: String, title: String, artist: String,
                                 requestKey: String) -> [String: Any] {
        let p = parseLxPlatform(songmid)
        return [
            "action": "musicLyric",
            "source": p.source,
            "info": [
                "musicInfo": [
                    "id": p.cleanId,
                    "songmid": p.cleanId,
                    "title": title,
                    "name": title,
                    "singer": artist,
                    "artist": artist,
                    "source": p.source,
                    "hash": p.cleanId,
                    "_quality": "128k",
                ],
                "requestContext": ["requestKey": requestKey, "requestType": "current"],
            ],
        ]
    }

    // MARK: 响应宽容解析（对照 wellmusic 4 级回退）

    /// musicUrl 响应提取 URL：result.data.url → result.url → result.data(字符串) → result(字符串)
    static func extractMusicUrl(from result: Any) -> String? {
        if let dict = result as? [String: Any] {
            if let data = dict["data"] as? [String: Any], let u = data["url"] as? String, !u.isEmpty {
                return u
            }
            if let u = dict["url"] as? String, !u.isEmpty {
                return u
            }
            if let s = dict["data"] as? String, !s.isEmpty {
                return s
            }
            if let s = dict["result"] as? String, !s.isEmpty {
                return s
            }
        } else if let s = result as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    /// musicSearch 响应提取：优先 result.data 数组，其次直接数组，容错取单条
    static func extractSongs(from result: Any) -> [WellLXSongResult] {
        var list: [Any] = []
        if let dict = result as? [String: Any] {
            if let data = dict["data"] as? [Any] { list = data }
            else if let data = dict["data"] as? [String: Any] { list = [data] }
            else if let data = dict["songs"] as? [Any] { list = data }
            else if let data = dict["result"] as? [Any] { list = data }
        } else if let arr = result as? [Any] {
            list = arr
        }
        var out: [WellLXSongResult] = []
        for item in list {
            guard let d = item as? [String: Any] else { continue }
            let title = (d["title"] as? String) ?? (d["name"] as? String) ?? ""
            guard !title.isEmpty else { continue }
            let id = stringValue(d["songmid"]) ?? stringValue(d["id"]) ?? stringValue(d["hash"]) ?? ""
            guard !id.isEmpty else { continue }
            out.append(WellLXSongResult(
                songmid: id,
                title: title,
                artist: stringValue(d["singer"]) ?? stringValue(d["artist"]) ?? "未知歌手",
                interval: (d["interval"] as? Int).map { TimeInterval($0) },
                album: stringValue(d["album"]),
                cover: stringValue(d["picUrl"]) ?? stringValue(d["pic"])
            ))
        }
        return out
    }

    static func extractLyric(from result: Any) -> String? {
        if let dict = result as? [String: Any] {
            if let s = dict["lrc"] as? [String: Any], let text = s["lyric"] as? String, !text.isEmpty {
                return text
            }
            if let s = dict["lyric"] as? String, !s.isEmpty { return s }
            if let s = dict["lrc"] as? String, !s.isEmpty { return s }
        } else if let s = result as? String, !s.isEmpty {
            return s
        }
        return nil
    }

    private static func stringValue(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: 音质映射

    /// 应用内音质档位 → lx 音质字符串
    static func quality(_ quality: WellAudioQuality) -> String {
        quality.lxQuality
    }
}