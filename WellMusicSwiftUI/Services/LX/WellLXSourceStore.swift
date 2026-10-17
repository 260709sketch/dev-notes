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

/// 音源脚本上报的更新提示（对应参考实现的 `lx.send('showUpdateAlert', …)`）。
struct WellLXUpdateNotice: Identifiable, Equatable {
    var id = UUID()
    /// 上报更新的音源 id（无法匹配到已导入音源时为 nil）
    var sourceID: String?
    var sourceName: String
    var log: String
    /// 更新链接（脚本未提供时为空）
    var updateUrl: String
    /// 应用侧检查到新版本时附带的远端脚本全文（非 nil = 弹窗里可一键更新）
    var inAppUpdateScript: String? = nil

    var hasLink: Bool { !updateUrl.isEmpty }
}

/// 「检查更新」的结果。
enum WellLXUpdateCheckResult: Equatable {
    /// 脚本未声明 srcUrl，无法在线检查
    case unavailable
    /// 拉取远端脚本失败
    case failed
    case upToDate
    case newer(version: String, script: String)
}

/// 音源自动更新设置键。
/// ⚠️ 必须放**文件级**：`WellLXSourceStore` 是 `@MainActor` 类，其 static 成员
/// 同样被主 actor 隔离 —— 设置页 Binding 闭包是非隔离上下文，直接读
/// `WellLXSourceStore.autoCheckUpdateKey` 会复现 2026-10-16 CI 的
/// 「call to main actor-isolated static property」编译错误。
enum WellLXSourceUpdateConfig {
    /// 启动时自动检查音源更新（总开关，默认开）
    static let autoCheckUpdateKey = "well.lx.autoCheckUpdate"
    /// 发现新版本时自动覆盖本地脚本（默认关 = 弹窗让用户确认）
    static let autoApplyUpdateKey = "well.lx.autoApplyUpdate"
}

/// 自定义音源（LX 脚本）仓库：负责导入、持久化、激活、测试与取链日志。
///
/// 与播放层的契约：`resolvePlayback(for:quality:)` 返回可直接播放的地址 + 请求头，
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
    /// 音源脚本上报的更新提示（待用户确认；确认/关闭后置空）
    @Published var pendingUpdateAlert: WellLXUpdateNotice?
    /// 已关闭「更新提示」的音源 id（不在集合里 = 开启，对齐参考实现的默认开启）
    @Published private(set) var updateAlertDisabledIDs: Set<String> = []

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
    /// 关闭了「更新提示」的音源 id 集合（未在集合中 = 开启，对齐参考实现的默认开启）
    private let updateAlertDisabledKey = "well.lx.updateAlertDisabledIDs"
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

    private init() {
        updateAlertDisabledIDs = Set(UserDefaults.standard.stringArray(forKey: updateAlertDisabledKey) ?? [])
    }

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
            // ★ 2026-10-16 第十轮问题2：激活即异步检查一次更新（12 小时/源节流）
            //   —— 用户「在别的平台用这个老音源都提醒更新」的路径就是切到该源时弹；
            //   脚本自检之外再兜一层应用侧检查，保证切源必查。
            scheduleUpdateCheckAfterActivation(for: source)
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

    // MARK: 音源更新提示

    /// 该音源是否允许弹出更新提示（默认允许）。
    func allowsUpdateAlert(for sourceID: String) -> Bool {
        !updateAlertDisabledIDs.contains(sourceID)
    }

    func setAllowsUpdateAlert(_ allows: Bool, for sourceID: String) {
        var set = updateAlertDisabledIDs
        if allows { set.remove(sourceID) } else { set.insert(sourceID) }
        updateAlertDisabledIDs = set
        defaults.set(Array(set), forKey: updateAlertDisabledKey)
    }

    /// 脚本上报更新（由 `WellLXEngine` 的通知转来）：按音源开关决定是否弹窗。
    /// - 关闭了提示的音源只写进请求日志，不打扰用户。
    func handleUpdateAlertNotification(name: String, log: String, updateUrl: String) {
        let target = sources.first(where: { $0.name == name }) ?? activeSource
        if let target, !allowsUpdateAlert(for: target.id) {
            appendLog(WellLXRequestLog(
                trackTitle: "音源更新提示",
                trackArtist: target.name,
                requestedQuality: "—",
                actualQuality: "—",
                url: "—",
                duration: 0,
                success: true,
                message: "已在设置中关闭更新提示：\(log)"
            ))
            return
        }
        pendingUpdateAlert = WellLXUpdateNotice(
            sourceID: target?.id,
            sourceName: name.isEmpty ? (target?.name ?? "音源") : name,
            log: log,
            updateUrl: updateUrl
        )
        // ★ 2026-10-17：脚本自报的更新也支持「立即更新」——后台拉取新脚本
        //   内容填进 inAppUpdateScript（拉到后按钮自动出现）。
        if !updateUrl.isEmpty {
            Task { @MainActor [weak self] in
                guard let self,
                      let fetched = try? await fetchScript(from: updateUrl),
                      fetched.contains("@name") || fetched.contains("lx_setup")
                          || fetched.contains("globalThis") else { return }
                if self.pendingUpdateAlert?.updateUrl == updateUrl {
                    self.pendingUpdateAlert?.inAppUpdateScript = fetched
                }
            }
        }
    }

    func dismissUpdateAlert() {
        pendingUpdateAlert = nil
    }

    // MARK: 启动自动检查更新（2026-10-16 用户问题4）

    /// 参考实现里更新提示由**脚本自行检查**（init 后查 srcUrl 再 `lx.send('showUpdateAlert')`），
    /// 但很多老音源没写这段自检 —— 用户原话：「音源检查更新是启动应用的时候检查，
    /// 不是手动检查的」+「自动更新替换本地包括关闭」。
    /// → 应用启动后逐源比对 `@version`：开了「自动更新」静默覆盖本地脚本，
    ///   否则弹窗提示（可在弹窗里一键更新）；两个开关都可在高级功能里关。

    /// 启动时自动检查音源更新（总开关，默认开）
    static let autoCheckUpdateKey = WellLXSourceUpdateConfig.autoCheckUpdateKey
    /// 发现新版本时自动覆盖本地脚本（默认关 = 弹窗让用户确认）
    static let autoApplyUpdateKey = WellLXSourceUpdateConfig.autoApplyUpdateKey

    private var didLaunchUpdateCheck = false

    /// 应用启动后调用一次：逐源在线检查更新。
    func runLaunchUpdateCheckIfNeeded() async {
        guard !didLaunchUpdateCheck else { return }
        didLaunchUpdateCheck = true
        let d = UserDefaults.standard
        guard (d.object(forKey: WellLXSourceUpdateConfig.autoCheckUpdateKey) as? Bool) ?? true else { return }
        guard !sources.isEmpty else { return }

        for source in sources {
            // 用户已关掉这个音源的更新提示 → 跳过，不打扰
            guard allowsUpdateAlert(for: source.id) else { continue }
            let result = await checkUpdate(for: source)
            guard case .newer(let version, let script) = result else { continue }

            if (d.object(forKey: WellLXSourceUpdateConfig.autoApplyUpdateKey) as? Bool) ?? false {
                do {
                    try await applyUpdate(script, to: source)
                    appendLog(WellLXRequestLog(
                        trackTitle: "音源自动更新",
                        trackArtist: source.name,
                        requestedQuality: "—",
                        actualQuality: "—",
                        url: "—",
                        duration: 0,
                        success: true,
                        message: "\(source.name) 已自动更新到 v\(version)"
                    ))
                } catch {
                    appendLog(WellLXRequestLog(
                        trackTitle: "音源自动更新",
                        trackArtist: source.name,
                        requestedQuality: "—",
                        actualQuality: "—",
                        url: "—",
                        duration: 0,
                        success: false,
                        message: "\(source.name) 自动更新失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                    ))
                }
            } else {
                let srcURL = scriptText(for: source).flatMap { WellLXProtocol.extractSrcUrl(from: $0) } ?? ""
                pendingUpdateAlert = WellLXUpdateNotice(
                    sourceID: source.id,
                    sourceName: source.name,
                    log: "发现新版本 v\(version)（当前 v\(source.version)）",
                    updateUrl: srcURL,
                    inAppUpdateScript: script.isEmpty ? nil : script
                )
                // 一次只弹一条，后续源等用户处理完再说
                return
            }
        }
    }

    /// 手动检查更新：拉取音源脚本自己声明的 `srcUrl`，比对头部 `@version`。
    /// 没有 srcUrl 的音源直接返回 `.unavailable`。
    func checkUpdate(for source: WellLXSourceInfo) async -> WellLXUpdateCheckResult {
        guard let script = scriptText(for: source) else { return .unavailable }
        let declared = WellLXProtocol.extractSrcUrl(from: script) ?? ""
        guard let url = Self.normalizedScriptURL(declared), !declared.isEmpty else {
            // ★ 2026-10-17 官方 LX 机制（用户画链路确认）：检查更新由**脚本自检**——
            //   脚本加载 → inited 回调 → 脚本自查并 lx.send(EVENT_NAMES.updateAlert)
            //   → 弹窗。此前无 srcUrl 直接放弃，脚本从没跑过 → 「检查不了」。
            //   现在把脚本在引擎里跑一遍，给 8 秒窗口等自报（自报会进
            //   pendingUpdateAlert 并弹全局弹窗）；超时 = 未发现更新。
            if let script = scriptText(for: source) {
                let noticeBefore = pendingUpdateAlert
                try? await WellLXEngine.shared.load(source: source, script: script)
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    if pendingUpdateAlert != nil, pendingUpdateAlert != noticeBefore {
                        return .upToDate   // 脚本已自弹更新弹窗
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            return .unavailable
        }
        guard let remote = try? await fetchScript(from: url) else {
            return .failed
        }
        var remoteVersion = WellLXProtocol.parseScriptInfo(remote).version
        var scriptForUpdate = remote
        if remoteVersion.isEmpty, remote.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
            // ★ 2026-10-16 用户：老音源的 update_url 是 JSON（如念心 wubian.json）
            //   —— 从 JSON 取版本与脚本地址，再拉脚本本体。
            if let data = remote.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let v = obj["version"] ?? obj["Version"] { remoteVersion = "\(v)" }
                if let candidate = (obj["srcUrl"] ?? obj["url"] ?? obj["scriptUrl"] ?? obj["download"]) as? String,
                   let u = Self.normalizedScriptURL(candidate),
                   let fresh = try? await fetchScript(from: u),
                   fresh.contains("@name") || fresh.contains("lx_setup") || fresh.contains("globalThis") {
                    scriptForUpdate = fresh
                    let freshVersion = WellLXProtocol.parseScriptInfo(fresh).version
                    if !freshVersion.isEmpty { remoteVersion = freshVersion }
                } else {
                    scriptForUpdate = ""
                }
            }
        }
        guard !remoteVersion.isEmpty, remoteVersion != source.version,
              Self.isNewer(remoteVersion, than: source.version) else {
            return .upToDate
        }
        return .newer(version: remoteVersion, script: scriptForUpdate)
    }

    /// 用「检查更新」拿到的远端脚本覆盖本地（同名音源原地升级，保持 id 不变）。
    func applyUpdate(_ script: String, to source: WellLXSourceInfo) async throws {
        // ★ 空脚本（JSON 更新页拿不到脚本本体）时只提示、不写文件
        guard !script.isEmpty else { return }
        let meta = WellLXProtocol.parseScriptInfo(script)
        try script.write(to: scriptURL(for: source.id), atomically: true, encoding: .utf8)
        update(source.id) {
            // 名称保持不变：远端脚本没声明 @name 时会被解析成「未命名音源」，就地改名会把用户导入的音源弄乱
            $0.sourceDescription = meta.description
            $0.version = meta.version
            $0.author = meta.author
            $0.homepage = meta.homepage
            $0.testStatus = .untested
            $0.platformTestResults = [:]
        }
        persistSources()
        if activeSourceID == source.id {
            await activate(sources.first(where: { $0.id == source.id }) ?? source)
        }
    }

    /// 激活后的更新检查（12 小时/源节流；弹窗复用 pendingUpdateAlert 底部卡片）。
    private func scheduleUpdateCheckAfterActivation(for source: WellLXSourceInfo) {
        let d = UserDefaults.standard
        guard (d.object(forKey: WellLXSourceUpdateConfig.autoCheckUpdateKey) as? Bool) ?? true else { return }
        let stampKey = "well.lx.lastActivateCheck.\(source.id)"
        let last = d.double(forKey: stampKey)
        guard Date().timeIntervalSince1970 - last > 12 * 3600 else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.checkUpdate(for: source)
            d.set(Date().timeIntervalSince1970, forKey: stampKey)
            guard case .newer(let version, let script) = result else { return }
            if self.pendingUpdateAlert == nil {
                let srcURL = self.scriptText(for: source).flatMap { WellLXProtocol.extractSrcUrl(from: $0) } ?? ""
                self.pendingUpdateAlert = WellLXUpdateNotice(
                    sourceID: source.id,
                    sourceName: source.name,
                    log: "发现新版本 v\(version)（当前 v\(source.version)）",
                    updateUrl: srcURL,
                    inAppUpdateScript: script
                )
            }
        }
    }

    private func fetchScript(from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WellLXStoreError.downloadFailed(http.statusCode)
        }
        let text = String(data: data, encoding: .utf8) ?? CryptoUtils.gbkString(data) ?? ""
        guard !text.isEmpty else { throw WellLXStoreError.emptyScript }
        return text
    }

    /// 版本号按数字分段比较（"1.10" > "1.9"）。
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let a = parts(lhs), b = parts(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: 播放解析

    /// 用自定义音源解析播放地址；全部音源失败时返回 nil，由调用方回退官方通道。
    func resolvePlayback(for item: MusicItem, quality: WellAudioQuality) async -> WellLXPlayback? {
        guard hasActiveSource else { return nil }
        await waitUntilReady()
        guard let active = activeSource else { return nil }

        let targetQuality = quality.lxQuality
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
                // ★ 2026-10-16 用户：音源状态「大小」列一直「—」——成功链接异步
                //   HEAD 取 Content-Length 回填（失败再 Range GET 兜底）
                let playbackHeaders = WellLXPlaybackHeaders.requestHeaders(
                    for: url, platform: WellLXPlaybackHeaders.platformKey(for: item))
                let logEntry = WellLXRequestLog(
                    trackTitle: item.title,
                    trackArtist: item.artist ?? "",
                    requestedQuality: targetQuality,
                    actualQuality: actualQuality,
                    url: url,
                    duration: Date().timeIntervalSince(started),
                    success: true,
                    message: isFallback ? "自动换源：\(source.name)" : nil
                )
                appendLog(logEntry)
                probeFileSizeAndPatch(logID: logEntry.id, urlString: url, headers: playbackHeaders)
                return WellLXPlayback(
                    url: url,
                    quality: actualQuality,
                    sourceName: source.name,
                    isFallback: isFallback,
                    headers: playbackHeaders
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

    /// 回填日志「大小」：HEAD 拿 Content-Length；HEAD 不可用（无长度/被拒）时
    /// 用 `Range: bytes=0-0` 的 GET 从 Content-Range 里取总大小。
    private func probeFileSizeAndPatch(logID: UUID, urlString: String, headers: [String: String]) {
        guard let url = URL(string: urlString) else { return }
        Task { [weak self] in
            var size: Int64 = 0
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            head.timeoutInterval = 8
            for (k, v) in headers { head.setValue(v, forHTTPHeaderField: k) }
            if let (_, response) = try? await URLSession.shared.data(for: head),
               let http = response as? HTTPURLResponse {
                if http.expectedContentLength > 0 {
                    size = http.expectedContentLength
                } else if let len = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(len) {
                    size = n
                }
            }
            if size <= 0 {
                var range = URLRequest(url: url)
                range.httpMethod = "GET"
                range.timeoutInterval = 8
                range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                for (k, v) in headers { range.setValue(v, forHTTPHeaderField: k) }
                if let (_, response) = try? await URLSession.shared.data(for: range),
                   let http = response as? HTTPURLResponse,
                   let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = contentRange.split(separator: "/").last, let n = Int64(total) {
                    size = n
                }
            }
            guard size > 0, let self else { return }
            await MainActor.run {
                if let idx = self.requestLogs.firstIndex(where: { $0.id == logID }) {
                    self.requestLogs[idx].fileSize = size
                }
            }
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