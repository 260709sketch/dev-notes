import Foundation
import os

// MARK: - 音源信息模型

/// 一条已导入的自定义音源（LX Music 音源脚本）。
/// 音源信息模型：平台 / 能力字段与 lx 音源脚本约定一致。
struct WellLXSourceInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var sourceDescription: String
    var version: String
    var author: String
    var homepage: String
    var importDate: Date
    /// 音源测试结果（不持久化，运行时刷新）。
    var testStatus: TestStatus? = nil
    /// 各平台测试结果（wy=网易云 / tx=QQ / kg=酷狗），nil=未测试
    var platformTestResults: [String: Bool] = [:]

    enum TestStatus: String, Codable {
        case untested
        case testing
        case working
        case failed
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case sourceDescription = "description"
        case version, author, homepage, importDate
    }
}

/// 音源初始化后声明的能力（支持哪些平台/操作/音质）。
struct WellLXSourceCapability: Hashable {
    let platform: String
    let name: String
    let actions: [String]
    let qualities: [String]
}

// MARK: - 错误

enum WellLXEngineError: LocalizedError {
    case notLoaded
    case initFailed(String)
    case requestFailed(String)
    case timeout
    case invalidResponse
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "音源未加载"
        case .initFailed(let m): return "音源初始化失败：\(m)"
        case .requestFailed(let m): return "音源请求失败：\(m)"
        case .timeout: return "音源请求超时"
        case .invalidResponse: return "音源返回无效"
        case .unsupported: return "音源不支持该操作"
        }
    }
}

// MARK: - 引擎

/// 基于 `WellLXScriptRunner`（JavaScriptCore 隔离运行时）的 LX Music 音源引擎。
///
/// 职责：复用现有 runner 完成「preload → lx_setup → 用户脚本」加载与 `request` 业务调用，
/// 向上暴露 **async** 接口（load / unload / musicURL / testMusicURL / lxQuality / lxMusicInfo），
/// 让 `WellLXSourceStore` 与播放解析层无需接触回调式 API。
///
/// 线程模型：`WellLXScriptRunner` 内部全量派发到串行 `queue`，本类不持有独立线程；
/// 仅对 `load`（重建整个 JS 环境）加保护，避免与业务请求并发。
final class WellLXEngine {

    static let shared = WellLXEngine()
    private init() {}

    private static let log = Logger(subsystem: "well.music.swiftui", category: "lxengine")

    private let runner = WellLXScriptRunner()

    /// 当前已加载音源。
    private(set) var currentSource: WellLXSourceInfo?
    /// 当前音源能力。
    private(set) var capabilities: [WellLXSourceCapability] = []

    /// `load` 在途保护：同一时刻只允许一次环境重建。
    private var isLoading = false

    // MARK: 加载 / 卸载

    /// 加载并初始化一条音源脚本。返回该音源声明的能力。
    func load(source: WellLXSourceInfo, script: String) async throws -> [WellLXSourceCapability] {
        guard !isLoading else {
            throw WellLXEngineError.initFailed("音源正在加载中")
        }
        isLoading = true
        defer { isLoading = false }

        let caps = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[WellLXSourceCapability], Error>) in
            runner.loadScript(WellLXScriptInfo(
                id: source.id,
                name: source.name,
                description: source.sourceDescription,
                author: source.author,
                homepage: source.homepage,
                version: source.version,
                srcUrl: "",
                script: script
            )) { [weak self] result in
                guard let self else {
                    cont.resume(throwing: WellLXEngineError.notLoaded)
                    return
                }
                if result.status {
                    let caps = self.extractCapabilities(from: result.sources)
                    self.currentSource = source
                    self.capabilities = caps
                    Self.log.info("加载音源 \(source.name, privacy: .public) 成功，能力 \(caps.count) 平台")
                    cont.resume(returning: caps)
                } else {
                    let message = result.errorMessage ?? "初始化失败"
                    Self.log.error("加载音源 \(source.name, privacy: .public) 失败：\(message, privacy: .public)")
                    cont.resume(throwing: WellLXEngineError.initFailed(message))
                }
            }
        }
        return caps
    }

    /// 卸载音源。
    func unload() async {
        runner.destroy()
        currentSource = nil
        capabilities = []
    }

    // MARK: 能力提取

    /// 从 init 上报的 sources 提取平台能力。
    /// preload 的 handleInit 上报结构为 `{ status, info: { sources: { platform: { type, actions, qualitys } } } }`。
    private func extractCapabilities(from sources: [String: Any]?) -> [WellLXSourceCapability] {
        guard let sources else { return [] }
        // sources 可能是整个 init 载荷，也可能是其中的 info（兼容两种）
        let sourceDicts: [String: Any]
        if let info = sources["info"] as? [String: Any], let src = info["sources"] as? [String: Any] {
            sourceDicts = src
        } else if let src = sources["sources"] as? [String: Any] {
            sourceDicts = src
        } else {
            sourceDicts = sources
        }
        var caps: [WellLXSourceCapability] = []
        for (platform, value) in sourceDicts {
            guard let s = value as? [String: Any] else { continue }
            caps.append(WellLXSourceCapability(
                platform: platform,
                name: platform,
                actions: (s["actions"] as? [String]) ?? [],
                qualities: (s["qualitys"] as? [String]) ?? []
            ))
        }
        return caps
    }

    // MARK: 业务请求（musicUrl 等）

    /// 获取播放 URL。
    func musicURL(for item: MusicItem, quality: String) async throws -> (url: String, quality: String) {
        guard currentSource != nil else { throw WellLXEngineError.notLoaded }

        // 从 song 以哪个平台调接口：网易云(wy) / QQ(tx) / 酷狗(kg) / 酷我(kw)
        let source = lxPlatform(for: item)
        // 平台不支持某音质时降级（QQ 音乐无 flac24bit）
        let adjustedQuality = (source == "tx" && quality == "flac24bit") ? "flac" : quality
        let musicInfo = lxMusicInfo(from: item, quality: adjustedQuality)

        let payload: [String: Any] = [
            "action": "musicUrl",
            "source": source,
            "info": [
                "type": adjustedQuality,
                "quality": adjustedQuality,
                "musicInfo": musicInfo,
            ],
        ]

        let result = try await callJS(action: "request", data: payload, timeout: 20)
        guard let dict = result as? [String: Any],
              let data = dict["data"] as? [String: Any],
              let url = data["url"] as? String, !url.isEmpty else {
            throw WellLXEngineError.invalidResponse
        }
        let actualQuality = (data["type"] as? String) ?? adjustedQuality
        return (url, actualQuality)
    }

    /// 测试音源是否能真正获取播放链接（用固定测试歌曲实际请求 musicUrl）。
    /// - Parameter platform: 测试平台，"wy"=网易云，"tx"=QQ，"kg"=酷狗
    func testMusicURL(platform: String = "wy") async -> Bool {
        guard currentSource != nil else { return false }
        let testItem = Self.testItem(platform)
        let qualities = ["128k", "320k", "flac"]
        for quality in qualities {
            do {
                let (url, _) = try await musicURL(for: testItem, quality: quality)
                if !url.isEmpty { return true }
            } catch {
                continue
            }
        }
        return false
    }

    // MARK: Swift -> JS

    /// 构造 `lx_music_utils` 等的请求 payload 并发往脚本，转成 async 结果。
    private func callJS(action: String, data: [String: Any], timeout: TimeInterval?) async throws -> Any {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            runner.callAction(action, data: data, timeout: timeout) { result in
                switch result {
                case .success(let value):
                    cont.resume(returning: value)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: 平台标识 / 音质映射

    /// `MusicItem.source` → lx 平台标识（wy / tx / kg / kw）
    func lxPlatform(for item: MusicItem) -> String {
        switch item.source {
        case .netease: return "wy"
        case .qq: return "tx"
        case .kugou: return "kg"
        case .kuwo: return "kw"
        case .auto:
            // 自动：按当前可用 id 推断，否则默认网易云
            if item.neteaseId != nil { return "wy" }
            if item.qqSongMid != nil { return "tx" }
            if item.kugouHash != nil { return "kg" }
            if item.kuwoRid != nil { return "kw" }
            return "wy"
        case .lx:
            // 已带平台前缀的 songmid，剥离前缀后返回
            let p = WellLXProtocol.parseLxPlatform(item.neteaseId ?? item.title)
            return p.source
        }
    }

    /// 应用内音质档位 → lx 音质字符串
    func lxQuality(from quality: WellAudioQuality) -> String {
        quality.lxQuality
    }

    /// MusicItem → lx 音源脚本期望的 musicInfo 标准格式。
    func lxMusicInfo(from item: MusicItem, quality: String = "128k") -> [String: Any] {
        let source = lxPlatform(for: item)
        let songmid = lxSongId(for: item)
        let pic = item.albumCoverURL ?? ""
        let singer = item.artist ?? ""
        let durationSec = Int(item.duration)
        let interval = String(format: "%02d:%02d", durationSec / 60, durationSec % 60)

        let qualityInfo: [[String: Any]] = [
            ["type": "128k", "size": ""],
            ["type": "320k", "size": ""],
            ["type": "flac", "size": ""],
        ]
        let qualityMap: [String: [String: String]] = [
            "128k": ["size": ""],
            "320k": ["size": ""],
            "flac": ["size": ""],
        ]

        var info: [String: Any] = [
            "name": item.title,
            "singer": singer,
            "source": source,
            "songmid": songmid,
            "interval": interval,
            "albumName": item.album ?? "",
            "img": pic,
            "typeUrl": [:] as [String: String],
            "albumId": "",
            "types": qualityInfo,
            "_types": qualityMap,
        ]

        // 按音源平台特殊处理
        switch source {
        case "kg":
            info["hash"] = item.kugouHash ?? songmid
        case "tx":
            // ⚠️ strMediaMid 是音频文件名用的**媒体 mid**（部分歌曲 ≠ songmid）。
            //    音源脚本按它拼 vkey 请求，填成 songmid 时一批歌会整体取链失败
            //    （表现为「这些歌在别的软件能放，这里放不了」）。
            let mediaMid = (item.qqMediaMid?.isEmpty == false ? item.qqMediaMid : nil) ?? songmid
            info["strMediaMid"] = mediaMid
            info["songmid"] = songmid
            info["albumMid"] = item.qqAlbumMid ?? ""
            info["songId"] = songmid
            info["vid"] = ""
        case "mg":
            info["copyrightId"] = ""
            info["lrcUrl"] = ""
            info["mrcUrl"] = ""
            info["trcUrl"] = ""
        default:
            break
        }

        return info
    }

    /// 取歌曲在该平台下的原始 ID（用于 songmid / hash）
    private func lxSongId(for item: MusicItem) -> String {
        switch item.source {
        case .netease: return item.neteaseId ?? ""
        case .qq: return item.qqSongMid ?? ""
        case .kugou: return item.kugouHash ?? ""
        case .kuwo: return item.kuwoRid ?? ""
        case .auto: return item.neteaseId ?? item.qqSongMid ?? item.kugouHash ?? item.kuwoRid ?? ""
        case .lx: return WellLXProtocol.parseLxPlatform(item.neteaseId ?? item.title).cleanId
        }
    }

    // MARK: 测试歌曲

    private static func testItem(_ platform: String) -> MusicItem {
        switch platform {
        case "tx":
            return MusicItem(source: .qq, title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269, qqSongMid: "003OUlho2HcRHC")
        case "kg":
            return MusicItem(source: .kugou, title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269, kugouHash: "7D9F8D5BEB6F0E7B7E5C0F5E1A8B3C2D")
        default:
            return MusicItem(source: .netease, title: "thank u, next", artist: "Ariana Grande", album: "thank u, next", duration: 207, neteaseId: "1330348068")
        }
    }
}
