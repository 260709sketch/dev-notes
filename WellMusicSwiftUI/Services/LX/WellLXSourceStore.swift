import Foundation
import os

// MARK: - 播放解析结果

/// 自定义音源解析出的播放信息。
struct WellLXPlayback {
    var url: String
    var quality: String
    /// 实际提供该地址的音源名称
    var sourceName: String
    /// 是否由非优先音源提供（自动换源）
    var isFallback: Bool
    /// 播放所需请求头（Referer / User-Agent）
    var headers: [String: String]
}

// MARK: - 请求日志

/// 一条自定义音源取链记录（仅保留最近若干条，便于排查）。
struct WellLXRequestLog: Identifiable, Hashable {
    let id = UUID()
    var date = Date()
    var trackTitle: String
    var trackArtist: String
    var requestedQuality: String
    var actualQuality: String
    var url: String
    var fileSize: Int64?
    var duration: TimeInterval
    var success: Bool
    var message: String?

    var durationText: String { String(format: "%.1fs", duration) }

    var fileSizeText: String {
        guard let fileSize, fileSize > 0 else { return "—" }
        let mb = Double(fileSize) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(fileSize) / 1024)
    }
}

// MARK: - 播放请求头（非隔离，可从任意线程/上下文调用）

/// 推导自定义音源播放所需的请求头。
///
/// 之所以独立成 enum：`WellLXSourceStore` 是 `@MainActor`，
/// 其静态成员也随之被主线程隔离，无法从 `MusicURLResolver` 这类非隔离上下文直接调用。
enum WellLXPlaybackHeaders {

    /// 推导播放所需的请求头。
    ///
    /// 优先级：
    /// 1. **曲目所属平台**（lx 平台标识 wy/tx/kg/kw）——这是最可靠的依据。
    ///    自定义音源返回的地址常落在与平台主体域名无关的 CDN 上（`*.bilivideo.*`、
    ///    裸 IP、短链等），仅靠域名匹配会推导不出 Referer，导致 CDN 403。
    /// 2. 域名启发式兜底——当平台信息缺失时，再按 URL 关键字判断。
    ///
    /// 始终附加桌面 UA：部分 CDN 对移动端 UA 返回 403 或降码率。
    static func requestHeaders(for url: String, platform: String? = nil) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        ]
        if let referer = refererHost(forPlatform: platform) {
            headers["Referer"] = referer
            return headers
        }
        if let referer = refererHost(forURL: url) {
            headers["Referer"] = referer
        }
        return headers
    }

    /// 由 lx 平台标识推导 Referer。
    private static func refererHost(forPlatform platform: String?) -> String? {
        switch platform {
        case "wy": return "https://music.163.com/"
        case "tx": return "https://y.qq.com/"
        case "kg": return "https://www.kugou.com/"
        case "kw": return "https://www.kuwo.cn/"
        case "mg": return "https://music.migu.cn/"
        default: return nil
        }
    }

    /// 域名启发式兜底（平台信息缺失时使用）。
    private static func refererHost(forURL url: String) -> String? {
        let lower = url.lowercased()
        // 酷狗
        if lower.contains("kugou") || lower.contains("kglink") { return "https://www.kugou.com/" }
        // 酷我
        if lower.contains("kuwo") { return "https://www.kuwo.cn/" }
        // 咪咕
        if lower.contains("migu") { return "https://music.migu.cn/" }
        // QQ / 腾讯系
        if lower.contains("qq.com") || lower.contains("tencent") || lower.contains("isure")
            || lower.contains("weixin") || lower.contains("myqcloud") || lower.contains("tme")
            || lower.contains("qqmusic") { return "https://y.qq.com/" }
        // 网易云
        if lower.contains("163") || lower.contains("netease") || lower.contains("nosdn")
            || lower.contains("music.126") { return "https://music.163.com/" }
        return nil
    }

    /// `MusicItem.source` → lx 平台标识（wy/tx/kg/kw/mg）。
    /// 供请求头推导使用；与 `WellLXEngine.lxPlatform(for:)` 保持一致。
    static func platformKey(for item: MusicItem) -> String? {
        switch item.source {
        case .netease: return "wy"
        case .qq: return "tx"
        case .kugou: return "kg"
        case .kuwo: return "kw"
        case .auto:
            if item.neteaseId != nil { return "wy" }
            if item.qqSongMid != nil { return "tx" }
            if item.kugouHash != nil { return "kg" }
            if item.kuwoRid != nil { return "kw" }
            return nil
        case .lx:
            return WellLXProtocol.parseLxPlatform(item.neteaseId ?? item.title).source
        }
    }
}

// MARK: - 音源仓库

/// 自定义音源（LX 脚本）仓库：负责导入、持久化、激活、测试与取链日志。
///
/// 与播放层的契约：`resolvePlayback(for:highQuality:)` 返回可直接播放的地址 + 请求头，
/// 调用方（`MusicURLResolver`）在解析失败时回退到官方平台通道，保证「听歌」不被阻断。
@MainActor
final class WellLXSourceStore: ObservableObject {

    static let shared = WellLXSourceStore()

    // MARK: 对外状态

    @Published private(set) var sources: [WellLXSourceInfo] = []
    @Published private(set) var activeSourceID: String?
    @Published private(set) var isInitializing = false
    @Published private(set) var lastError: String?
    @Published private(set) var requestLogs: [WellLXRequestLog] = []

    /// 当前激活的音源（未激活时为 nil）。
    var activeSource: WellLXSourceInfo? {
        guard let activeSourceID else { return nil }
        return sources.first { $0.id == activeSourceID }
    }

    var hasActiveSource: Bool { activeSource != nil }

    // MARK: 内部

    private static let log = Logger(subsystem: "well.music.swiftui", category: "lxstore")

    private let defaults = UserDefaults.standard
    private let activeKey = "well.lx.activeSourceID"
    private let logLimit = 50

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var didBootstrap = false

    private init() {}

    // MARK: 目录

    private var baseDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("CustomSources", isDirectory: true)
    }

    private var scriptsDirectory: URL {
        baseDirectory.appendingPathComponent("scripts", isDirectory: true)
    }

    private var manifestURL: URL {
        baseDirectory.appendingPathComponent("sources.json")
    }

    private func scriptURL(for id: String) -> URL {
        scriptsDirectory.appendingPathComponent("\(id).js")
    }

    private func ensureDirectories() {
        let fm = FileManager.default
        for dir in [baseDirectory, scriptsDirectory] where !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: 启动恢复

    /// 应用启动时调用：读取已保存的音源列表并恢复激活状态。
    func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        ensureDirectories()
        restoreSources()
        await restoreActiveSource()
    }

    private func restoreSources() {
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? decoder.decode([WellLXSourceInfo].self, from: data) else {
            sources = []
            return
        }
        // 过滤掉脚本文件已丢失的条目
        sources = list.filter { FileManager.default.fileExists(atPath: scriptURL(for: $0.id).path) }
    }

    private func restoreActiveSource() async {
        let saved = defaults.string(forKey: activeKey)
        guard let target = sources.first(where: { $0.id == saved }) ?? sources.first else {
            activeSourceID = nil
            return
        }
        await activate(target)
    }

    /// 等待激活流程结束（供取链前调用）。
    func waitUntilReady() async {
        guard isInitializing else { return }
        let deadline = Date().addingTimeInterval(8)
        while isInitializing, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: 导入

    /// 从脚本文本导入。
    @discardableResult
    func importScript(_ text: String) async throws -> WellLXSourceInfo {
        let script = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { throw WellLXStoreError.emptyScript }
        guard WellLXProtocol.isLxMusicScript(script) else { throw WellLXStoreError.notCustomSourceScript }

        ensureDirectories()
        let meta = WellLXProtocol.parseScriptInfo(script)
        let id = "well_api_\(Int.random(in: 100...999))_\(Int(Date().timeIntervalSince1970 * 1000))"

        // 同名同版本同作者的音源视为重复
        if sources.contains(where: { $0.name == meta.name && $0.version == meta.version && $0.author == meta.author }) {
            throw WellLXStoreError.duplicated
        }

        let info = WellLXSourceInfo(
            id: id,
            name: meta.name,
            sourceDescription: meta.description,
            version: meta.version,
            author: meta.author,
            homepage: meta.homepage,
            importDate: Date(),
            testStatus: .untested,
            platformTestResults: [:]
        )

        try script.write(to: scriptURL(for: id), atomically: true, encoding: .utf8)
        sources.append(info)
        persistSources()
        await activate(info)
        return info
    }

    /// 从 URL 导入（GitHub blob 链接自动转换为 raw 直链）。
    @discardableResult
    func importFromURL(_ urlString: String) async throws -> WellLXSourceInfo {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.normalizedScriptURL(trimmed) else { throw WellLXStoreError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WellLXStoreError.downloadFailed(http.statusCode)
        }
        let text = String(data: data, encoding: .utf8) ?? CryptoUtils.gbkString(data) ?? ""
        guard !text.isEmpty else { throw WellLXStoreError.emptyScript }
        return try await importScript(text)
    }

    /// 把 github.com/.../blob/... 转为 raw.githubusercontent.com 直链。
    private static func normalizedScriptURL(_ string: String) -> URL? {
        guard let url = URL(string: string) else { return nil }
        guard url.host?.contains("github.com") == true else { return url }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, parts[2] == "blob" else { return url }
        let path = "/" + [parts[0], parts[1], parts[3], parts[4...].joined(separator: "/")].joined(separator: "/")
        return URL(string: "https://raw.githubusercontent.com" + path) ?? url
    }

    // MARK: 删除

    func remove(_ source: WellLXSourceInfo) async {
        sources.removeAll { $0.id == source.id }
        try? FileManager.default.removeItem(at: scriptURL(for: source.id))
        persistSources()
        if activeSourceID == source.id {
            await deactivate()
        }
    }

    // MARK: 激活 / 停用

    /// 激活指定音源（会重建 JS 环境）。
    func activate(_ source: WellLXSourceInfo) async {
        guard let script = scriptText(for: source) else {
            lastError = "音源脚本文件缺失"
            return
        }
        isInitializing = true
        defer { isInitializing = false }

        do {
            let capabilities = try await WellLXEngine.shared.load(source: source, script: script)
            guard !capabilities.isEmpty else {
                lastError = "音源未声明任何可用平台"
                await WellLXEngine.shared.unload()
                activeSourceID = nil
                defaults.set(nil, forKey: activeKey)
                return
            }
            activeSourceID = source.id
            lastError = nil
            defaults.set(source.id, forKey: activeKey)
            Self.log.info("激活音源 \(source.name, privacy: .public)，可用平台 \(capabilities.count)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            activeSourceID = nil
            defaults.set(nil, forKey: activeKey)
            Self.log.error("激活音源失败：\(message, privacy: .public)")
        }
    }

    func deactivate() async {
        await WellLXEngine.shared.unload()
        activeSourceID = nil
        defaults.set(nil, forKey: activeKey)
    }

    /// 设为优先：置顶并激活。
    func setPriority(_ source: WellLXSourceInfo) async {
        if let idx = sources.firstIndex(where: { $0.id == source.id }) {
            let moved = sources.remove(at: idx)
            sources.insert(moved, at: 0)
            persistSources()
        }
        await activate(source)
    }

    // MARK: 测试

    /// 依次测试音源在网易云 / QQ / 酷狗 上能否真正取到播放地址，并回填测试结果。
    func test(_ source: WellLXSourceInfo) async {
        let previousID = activeSourceID
        update(source.id) { $0.testStatus = .testing; $0.platformTestResults = [:] }
        await activate(source)

        guard activeSourceID == source.id else {
            update(source.id) { $0.testStatus = .failed }
            return
        }

        var results: [String: Bool] = [:]
        for platform in ["wy", "tx", "kg"] {
            results[platform] = await WellLXEngine.shared.testMusicURL(platform: platform)
        }
        update(source.id) {
            $0.platformTestResults = results
            $0.testStatus = results.values.contains(true) ? .working : .failed
        }

        // 恢复原激活状态
        if let previousID, previousID != source.id,
           let previous = sources.first(where: { $0.id == previousID }) {
            await activate(previous)
        } else if previousID == nil {
            await deactivate()
        }
    }

    private func update(_ id: String, _ mutate: (inout WellLXSourceInfo) -> Void) {
        guard let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        var item = sources[idx]
        mutate(&item)
        sources[idx] = item
    }

    // MARK: 播放解析

    /// 用自定义音源解析播放地址；全部音源失败时返回 nil，由调用方回退官方通道。
    func resolvePlayback(for item: MusicItem, highQuality: Bool) async -> WellLXPlayback? {
        guard hasActiveSource else { return nil }
        await waitUntilReady()
        guard let active = activeSource else { return nil }

        let targetQuality = highQuality ? "flac" : "128k"
        var order: [WellLXSourceInfo] = [active]
        order.append(contentsOf: sources.filter { $0.id != active.id })

        for source in order {
            if WellLXEngine.shared.currentSource?.id != source.id {
                guard let script = scriptText(for: source) else { continue }
                _ = try? await WellLXEngine.shared.load(source: source, script: script)
            }
            guard WellLXEngine.shared.currentSource?.id == source.id else { continue }

            let started = Date()
            do {
                let (rawURL, actualQuality) = try await WellLXEngine.shared.musicURL(for: item, quality: targetQuality)
                let url = rawURL.replacingOccurrences(of: " ", with: "%20")
                guard !url.isEmpty else { continue }
                let isFallback = source.id != active.id
                appendLog(WellLXRequestLog(
                    trackTitle: item.title,
                    trackArtist: item.artist ?? "",
                    requestedQuality: targetQuality,
                    actualQuality: actualQuality,
                    url: url,
                    duration: Date().timeIntervalSince(started),
                    success: true,
                    message: isFallback ? "自动换源：\(source.name)" : nil
                ))
                return WellLXPlayback(
                    url: url,
                    quality: actualQuality,
                    sourceName: source.name,
                    isFallback: isFallback,
                    headers: WellLXPlaybackHeaders.requestHeaders(
                        for: url,
                        platform: WellLXPlaybackHeaders.platformKey(for: item))
                )
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                appendLog(WellLXRequestLog(
                    trackTitle: item.title,
                    trackArtist: item.artist ?? "",
                    requestedQuality: targetQuality,
                    actualQuality: "—",
                    url: "—",
                    duration: Date().timeIntervalSince(started),
                    success: false,
                    message: "\(source.name)：\(message)"
                ))
                continue
            }
        }
        return nil
    }

    // MARK: 日志

    private func appendLog(_ entry: WellLXRequestLog) {
        requestLogs.insert(entry, at: 0)
        if requestLogs.count > logLimit {
            requestLogs.removeLast(requestLogs.count - logLimit)
        }
    }

    func clearLogs() {
        requestLogs.removeAll()
    }

    // MARK: 持久化

    private func scriptText(for source: WellLXSourceInfo) -> String? {
        try? String(contentsOf: scriptURL(for: source.id), encoding: .utf8)
    }

    private func persistSources() {
        ensureDirectories()
        guard let data = try? encoder.encode(sources) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}

// MARK: - 错误

enum WellLXStoreError: LocalizedError {
    case emptyScript
    case notCustomSourceScript
    case duplicated
    case invalidURL
    case downloadFailed(Int)

    var errorDescription: String? {
        switch self {
        case .emptyScript: return "脚本内容为空"
        case .notCustomSourceScript: return "不是有效的自定义音源脚本"
        case .duplicated: return "该音源已存在"
        case .invalidURL: return "音源链接无效"
        case .downloadFailed(let code): return "下载音源失败（\(code)）"
        }
    }
}