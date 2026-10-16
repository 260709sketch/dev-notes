import SwiftUI
import UIKit

// MARK: - 文案（文件级自由函数）

/// ⚠️ 这两个必须放在**文件级**，不能做成 `WellLXSourceTestModel` 的 static 方法 ——
/// 那个类是 `@MainActor`，其 static 成员会被主 actor 隔离，
/// 而 `WellLXPlatformTestResult.qualityShort` 是非隔离上下文，
/// CI 实报「call to main actor-isolated static method 'qualityLabel'
/// in a synchronous nonisolated context」。
func wellLXQualityLabel(_ quality: String) -> String {
    switch quality {
    case "master": return "母带"
    case "atmos_plus": return "ATMOS+"
    case "atmos": return "ATMOS"
    case "hires": return "Hi-Res"
    case "flac": return "FLAC"
    case "320k": return "320K"
    case "128k": return "128K"
    default: return quality
    }
}

func wellLXStateText(_ state: WellLXPlatformTestResult.State) -> String {
    switch state {
    case .pending: return "待测试"
    case .testing: return "测试中…"
    case .success: return "可用"
    case .failed: return "不可用"
    }
}

// MARK: - 结果模型

/// 单个平台的测试结果。
struct WellLXPlatformTestResult: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case testing
        case success
        case failed
    }

    /// 平台标识：kw / kg / tx / wy / mg
    var id: String
    var platformName: String
    var keyword: String
    var state: State = .pending
    /// 搜索命中的歌曲（"歌名 - 歌手"）
    var searchedSong: String = ""
    /// 全流程耗时
    var delay: TimeInterval?
    /// 实际能取到的最高音质
    var maxQuality: String?
    /// 失败原因 / 降级说明
    var message: String = ""
    /// 逐档明细（"母带 ✓ 1.2s"）
    var qualityDetails: [String] = []

    var qualityShort: String {
        guard let maxQuality else { return "—" }
        return wellLXQualityLabel(maxQuality)
    }
}

// MARK: - 视图模型

/// 音源测试（问题12）：对五大平台（酷我 / 酷狗 / QQ / 网易 / 咪咕）逐个跑
/// 「搜索 → 逐档取链」完整链路，产出「支持哪些平台 / 每个平台最高可用音质」的结论。
///
/// 与参考实现一致：关键词可自定义、超时与是否显示错误/降级可调、可随时停止、结果可复制。
@MainActor
final class WellLXSourceTestModel: ObservableObject {

    struct Platform: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// 测试平台（2026-10-16 用户：移除咪咕和酷我，只留酷狗 / QQ / 网易）
    static let platforms: [Platform] = [
        Platform(id: "kg", name: "酷狗"),
        Platform(id: "tx", name: "QQ"),
        Platform(id: "wy", name: "网易"),
    ]

    /// 音质档位（由高到低逐档测试，取第一个成功档为「最高可用」）。
    /// ★ 2026-10-16 用户：本应用最高音质到 Hi-Res，更高档位（母带/全景声）不测。
    static let qualityLevels = ["hires", "flac", "320k", "128k"]

    /// 默认测试关键词
    static func defaultKeyword(for platform: String) -> String {
        "晴天"
    }

    // MARK: 对外状态

    @Published private(set) var results: [WellLXPlatformTestResult] = []
    @Published private(set) var isRunning = false
    // ★ 2026-10-16 用户：测试日志整体移除（append 保留为空操作，少动 30 处调用点）
    @Published private(set) var keywords: [String: String] = [:]
    @Published var testTimeoutSeconds = 20
    @Published var qualityTimeoutSeconds = 5
    @Published var showErrors = true
    @Published var showDowngrades = true
    /// 音源能力版本号：激活的钱包音源变化后 +1，驱动「支持平台」重新计算
    @Published private(set) var capabilityRevision = 0

    // MARK: 内部

    private var stopRequested = false
    private var didLoad = false

    private let keywordPrefix = "well.lx.srctest.keyword."
    private let testTimeoutKey = "well.lx.srctest.timeout"
    private let qualityTimeoutKey = "well.lx.srctest.qtimeout"
    private let showErrorsKey = "well.lx.srctest.showErrors"
    private let showDowngradesKey = "well.lx.srctest.showDowngrades"

    private static let reportFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: 读写设置

    func loadIfNeeded() {
        let defaults = UserDefaults.standard
        if !didLoad {
            didLoad = true
            var map: [String: String] = [:]
            for platform in Self.platforms {
                map[platform.id] = defaults.string(forKey: keywordPrefix + platform.id)
                    ?? Self.defaultKeyword(for: platform.id)
            }
            keywords = map
            testTimeoutSeconds = (defaults.object(forKey: testTimeoutKey) as? Int) ?? 20
            qualityTimeoutSeconds = (defaults.object(forKey: qualityTimeoutKey) as? Int) ?? 5
            showErrors = (defaults.object(forKey: showErrorsKey) as? Bool) ?? true
            showDowngrades = (defaults.object(forKey: showDowngradesKey) as? Bool) ?? true
        }
        capabilityRevision &+= 1
    }

    func keyword(for platform: String) -> String {
        keywords[platform] ?? Self.defaultKeyword(for: platform)
    }

    func setKeyword(_ value: String, for platform: String) {
        keywords[platform] = value
        UserDefaults.standard.set(value, forKey: keywordPrefix + platform)
    }

    func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(testTimeoutSeconds, forKey: testTimeoutKey)
        defaults.set(qualityTimeoutSeconds, forKey: qualityTimeoutKey)
        defaults.set(showErrors, forKey: showErrorsKey)
        defaults.set(showDowngrades, forKey: showDowngradesKey)
    }

    // MARK: 支持的平台

    /// 当前音源声明的能力里，哪些平台有可用音质（空 = 该音源不支持该平台）。
    var supportedPlatformsText: String {
        let capabilities = WellLXEngine.shared.capabilities
        let names = Self.platforms.filter { platform in
            (capabilities.first { $0.platform == platform.id }?.qualities.count ?? 0) > 0
        }.map { $0.name }
        return names.isEmpty ? "无" : names.joined(separator: "、")
    }

    var activeSourceName: String {
        WellLXEngine.shared.currentSource?.name ?? WellLXSourceStore.shared.activeSource?.name ?? "未激活"
    }

    // MARK: 运行

    /// ★ 2026-10-16 用户：测试一次后换其他音源「秒返回成功」——
    ///   根因是引擎里还挂着**上一个音源**（切源后引擎未必重建，旧脚本环境残留）。
    ///   每次开测前把当前激活音源**强制重载**进引擎，保证测的就是所选音源。
    func start() {
        guard !isRunning else { return }
        guard let active = WellLXSourceStore.shared.activeSource else {
            results = []
            ToastCenter.shared.show("请先在「自定义音源」里导入并启用音源")
            return
        }
        stopRequested = false
        isRunning = true
        results = Self.platforms.map {
            WellLXPlatformTestResult(id: $0.id, platformName: $0.name, keyword: keyword(for: $0.id))
        }
        Task {
            // 强制重载（activate 内部会重建引擎环境）
            await WellLXSourceStore.shared.activate(active)
            await runAll()
        }
    }

    /// 快捷换源测试（2026-10-16 用户问题4）：切激活音源并清空旧结果。
    func switchSource(_ source: WellLXSourceInfo) async {
        guard !isRunning else { return }
        await WellLXSourceStore.shared.activate(source)
        results = []
        capabilityRevision &+= 1
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
        isRunning = false
    }

    private func runAll() async {
        for (index, platform) in Self.platforms.enumerated() {
            if stopRequested {
                for rest in index..<Self.platforms.count where results[rest].state == .pending {
                    results[rest].state = .failed
                    results[rest].message = "已停止"
                }
                break
            }
            results[index].state = .testing
            let outcome = await test(platform: platform, keyword: keyword(for: platform.id))
            results[index] = outcome
        }
        isRunning = false
        stopRequested = false
        // 让「支持平台」按最新能力刷新
        capabilityRevision &+= 1
    }

    /// 单个平台的定位结果（测试歌曲 + 取链元数据）。
    private struct ProbeSong {
        var songmid: String
        var title: String
        var artist: String
        var mediaMid: String?
        var copyrightId: String?
        var origin: String
    }

    /// 定位测试歌曲。
    ///
    /// ★ 2026-10-16 用户问题5：「源测试没用，点击测试没反应/全部搜索为空」。
    /// 根因：标准 LX 音源脚本的 request 处理器只实现了 `musicUrl / pic / lyric`，
    /// **没有 `musicSearch`** —— 原实现第一步就向脚本要搜索，必然全平台空手而归。
    /// 新流程：
    ///   ① 先按 lx 协议试 `musicSearch`（个别音源支持就白赚）；
    ///   ② 不支持/为空 → **用应用内各平台曲库搜索**定位真实歌曲（kw/kg/tx/wy
    ///      都有现成通道），再拿真实 id 让音源逐档取链 —— 这才是要测的东西
    ///      「音源能不能给各平台取到链接」。
    private func probeSong(platform: Platform, keyword: String) async -> ProbeSong? {
        // ① lx 协议搜索（尽力而为）
        if let songs = try? await WellLXEngine.shared.search(
            keyword: keyword, source: platform.id, page: 1, pageSize: 1,
            timeout: TimeInterval(min(testTimeoutSeconds, 10))
        ), let song = songs.first {
            return ProbeSong(
                songmid: song.songmid, title: song.title, artist: song.artist,
                mediaMid: song.mediaMid, copyrightId: song.copyrightId,
                origin: "音源搜索")
        }

        // ② 应用内曲库搜索（真实 id）
        let item: MusicItem?
        switch platform.id {
        case "wy":
            item = (try? await NeteaseMusicAPI.shared.search(keyword: keyword, limit: 5))?.first
        case "tx":
            item = (try? await QQMusicAPI.shared.search(keyword: keyword, limit: 5))?.first
        case "kg":
            item = (try? await KugouMusicAPI.shared.search(keyword: keyword, limit: 5))?.first
        case "kw":
            item = (try? await KuwoMusicAPI.shared.search(keyword: keyword, limit: 5))?.first
        default:
            item = nil
        }
        guard let item else { return nil }
        let songmid: String?
        let mediaMid: String?
        switch platform.id {
        case "wy": songmid = item.neteaseId; mediaMid = nil
        case "tx": songmid = item.qqSongMid; mediaMid = item.qqMediaMid
        case "kg": songmid = item.kugouHash; mediaMid = nil
        case "kw": songmid = item.kuwoRid; mediaMid = nil
        default: songmid = nil; mediaMid = nil
        }
        guard let songmid, !songmid.isEmpty else { return nil }
        return ProbeSong(
            songmid: songmid,
            title: item.title,
            artist: item.artist ?? "",
            mediaMid: (mediaMid?.isEmpty == false) ? mediaMid : nil,
            copyrightId: nil,
            origin: "应用内曲库")
    }

    /// 单档取链（重试复用）。
    private static func probeOnce(
        songmid: String, song: ProbeSong, quality: String, timeout: TimeInterval
    ) async throws -> (String, String) {
        try await WellLXEngine.shared.musicURL(
            songmid: songmid,
            title: song.title,
            artist: song.artist,
            quality: quality,
            mediaMid: song.mediaMid,
            copyrightId: song.copyrightId,
            timeout: timeout
        )
    }

    private func test(platform: Platform, keyword: String) async -> WellLXPlatformTestResult {
        var result = WellLXPlatformTestResult(id: platform.id, platformName: platform.name, keyword: keyword)
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            result.state = .failed
            result.message = "关键词为空"
            return result
        }
        let started = Date()
        append("[\(platform.name)] 开始测试，关键词「\(trimmed)」")

        guard let song = await probeSong(platform: platform, keyword: trimmed) else {
            result.state = .failed
            result.message = platform.id == "mg"
                ? "无法定位测试歌曲（应用内无咪咕曲库通道，且当前音源不支持搜索）"
                : "无法定位测试歌曲（音源与应用内曲库均未命中，换个关键词试试）"
            append("[\(platform.name)] \(result.message)")
            return result
        }
        result.searchedSong = "\(song.title) - \(song.artist)"
        append("[\(platform.name)] 测试歌曲（\(song.origin)）：\(result.searchedSong)")

        let songmid = "\(platform.id)_\(song.songmid)"
        var details: [String] = []
        var errors: [String] = []
        var downgrades: [String] = []
        var maxQuality: String?

        for quality in Self.qualityLevels {
            if stopRequested { break }
            // ★ 2026-10-16 第十轮问题1：档位之间加间隔 —— 很多音源脚本内置
            //   「2 秒内仅允许 N 次解析」的自限流，连打 4 档必然吃限流
            //   （截图：网易「请求限流」、QQ/酷狗「未获取到有效播放链接」）。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if stopRequested { break }
            let qualityStarted = Date()
            do {
                let (url, actual) = try await Self.probeOnce(
                    songmid: songmid, song: song, quality: quality,
                    timeout: TimeInterval(qualityTimeoutSeconds))
                guard !url.isEmpty else { throw WellLXEngineError.invalidResponse }
                let used = Date().timeIntervalSince(qualityStarted)
                if maxQuality == nil { maxQuality = actual }
                // ★ 2026-10-16 用户：不足 1 秒的档位显示毫秒（本地秒回的源
                //   原来会显示「0.0s」，看起来像没测）
                let usedText = used >= 1
                    ? String(format: "%.1fs", used)
                    : String(format: "%.0fms", used * 1000)
                details.append("\(wellLXQualityLabel(quality)) ✓ \(usedText)")
                if showDowngrades, actual != quality {
                    downgrades.append("\(wellLXQualityLabel(quality))→\(wellLXQualityLabel(actual))")
                }
            } catch {
                let text = errorText(error)
                // 限流识别：等 2.5s 重试一次；重试仍限流则明确标注（不误导为不可用）
                if text.contains("限流") || text.contains("过于频繁") {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if let retry = try? await Self.probeOnce(
                        songmid: songmid, song: song, quality: quality,
                        timeout: TimeInterval(qualityTimeoutSeconds)),
                       !retry.0.isEmpty {
                        if maxQuality == nil { maxQuality = retry.1 }
                        details.append("\(wellLXQualityLabel(quality)) ✓ 重试成功")
                        continue
                    }
                    details.append("\(wellLXQualityLabel(quality)) ⏳ 限流")
                    errors.append("\(wellLXQualityLabel(quality))：音源限流，稍后再试")
                } else {
                    details.append("\(wellLXQualityLabel(quality)) ✗")
                    errors.append("\(wellLXQualityLabel(quality))：\(text)")
                }
            }
        }

        result.qualityDetails = details
        result.maxQuality = maxQuality
        result.delay = Date().timeIntervalSince(started)

        var messages: [String] = []
        if let maxQuality {
            result.state = .success
            messages.append("最高可用：\(wellLXQualityLabel(maxQuality))")
        } else {
            result.state = .failed
            messages.append("全部音质均不可用")
        }
        if showDowngrades, !downgrades.isEmpty {
            messages.append("降级：" + downgrades.joined(separator: "、"))
        }
        if showErrors, !errors.isEmpty {
            messages.append("失败：" + errors.joined(separator: "；"))
        }
        result.message = messages.joined(separator: "\n")
        append("[\(platform.name)] 完成：\(result.message.replacingOccurrences(of: "\n", with: " / "))")
        return result
    }

    // MARK: 报告

    /// 纯文本报告，供复制分享。
    var reportText: String {
        var lines: [String] = []
        lines.append("音源测试报告 · \(activeSourceName)")
        lines.append("测试时间：\(Self.reportFormatter.string(from: Date()))")
        lines.append("支持平台：\(supportedPlatformsText)")
        if results.isEmpty {
            lines.append("（暂无测试结果）")
        }
        for result in results {
            lines.append("")
            lines.append("【\(result.platformName)】\(wellLXStateText(result.state))　最高音质：\(result.qualityShort)")
            if !result.searchedSong.isEmpty { lines.append("  命中：\(result.searchedSong)") }
            if let delay = result.delay { lines.append(String(format: "  耗时：%.1fs", delay)) }
            if !result.qualityDetails.isEmpty {
                lines.append("  音质：\(result.qualityDetails.joined(separator: "  "))")
            }
            if !result.message.isEmpty {
                lines.append("  \(result.message.replacingOccurrences(of: "\n", with: "　"))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func append(_ line: String) {
        // 测试日志已按用户要求整体移除（2026-10-16）；保留空实现以免改动全部调用点
    }

    private func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 视图

/// 音源源测试页（设置 → 播放/高级功能 → 音源测试）。
struct WellLXSourceTestView: View {
    @StateObject private var model = WellLXSourceTestModel()
    @ObservedObject private var store = WellLXSourceStore.shared

    var body: some View {
        Form {
            statusSection
            keywordSection
            settingsSection
            if !model.results.isEmpty { resultSection }
        }
        .navigationTitle("音源测试")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if model.isRunning {
                        Button { model.stop() } label: { Label("停止测试", systemImage: "stop.circle") }
                    } else {
                        Button { model.start() } label: { Label("开始测试", systemImage: "play.circle") }
                            .disabled(store.activeSource == nil)
                    }
                    Button {
                        UIPasteboard.general.string = model.reportText
                        ToastCenter.shared.show("测试结果已复制")
                    } label: { Label("复制结果", systemImage: "doc.on.doc") }
                    .disabled(model.results.isEmpty)
                } label: {
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { model.loadIfNeeded() }
    }

    // MARK: 当前音源

    private var statusSection: some View {
        Section {
            HStack {
                Label("当前音源", systemImage: "music.note")
                Spacer()
                Text(model.activeSourceName).foregroundStyle(.secondary)
            }
            // ★ 2026-10-16 用户问题4：测试页内快捷更换音源，不必来回进设置
            if store.sources.count > 1 {
                Menu {
                    ForEach(store.sources) { source in
                        Button {
                            Task { await model.switchSource(source) }
                        } label: {
                            HStack {
                                Text(source.name)
                                if source.id == store.activeSourceID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label("换一个音源测试", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Label("支持平台", systemImage: "square.stack.3d.up")
                Spacer()
                Text(model.supportedPlatformsText).foregroundStyle(.secondary)
            }
            Button {
                model.start()
            } label: {
                HStack {
                    Spacer()
                    Label(model.isRunning ? "测试中…" : "开始测试", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                    Spacer()
                }
            }
            .disabled(model.isRunning || store.activeSource == nil)
        } footer: {
            Text("逐个平台执行「搜索歌曲 → 逐档请求播放地址」，测出该音源实际支持哪些平台、每个平台最高能取到哪一档音质。本应用最高支持 Hi-Res，更高档位不在测试范围。")
        }
    }

    // MARK: 关键词

    private var keywordSection: some View {
        Section {
            ForEach(WellLXSourceTestModel.platforms) { platform in
                HStack {
                    Text(platform.name).frame(width: 48, alignment: .leading)
                    TextField("测试关键词", text: Binding(
                        get: { model.keyword(for: platform.id) },
                        set: { newValue in model.setKeyword(newValue, for: platform.id) }
                    ))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }
            }
        } header: {
            Text("测试关键词")
        } footer: {
            Text("每个平台可分别填写用于搜索的歌名，测试时各取搜索结果第一条。")
        }
    }

    // MARK: 设置

    private var settingsSection: some View {
        Section("测试设置") {
            Stepper(value: $model.testTimeoutSeconds, in: 5...60, step: 5) {
                HStack {
                    Text("搜索超时")
                    Spacer()
                    Text("\(model.testTimeoutSeconds) 秒").foregroundStyle(.secondary)
                }
            }
            Stepper(value: $model.qualityTimeoutSeconds, in: 1...30, step: 1) {
                HStack {
                    Text("单档取链超时")
                    Spacer()
                    Text("\(model.qualityTimeoutSeconds) 秒").foregroundStyle(.secondary)
                }
            }
            Toggle("显示失败原因", isOn: $model.showErrors)
            Toggle("显示音质降级", isOn: $model.showDowngrades)
        }
        .onChange(of: model.testTimeoutSeconds) { _ in model.persistSettings() }
        .onChange(of: model.qualityTimeoutSeconds) { _ in model.persistSettings() }
        .onChange(of: model.showErrors) { _ in model.persistSettings() }
        .onChange(of: model.showDowngrades) { _ in model.persistSettings() }
    }

    // MARK: 结果

    private var resultSection: some View {
        Section {
            ForEach(model.results) { result in
                WellLXPlatformResultRow(result: result)
            }
        } header: {
            Text("测试结果")
        } footer: {
            Text("「最高音质」= 由高到低逐档请求后第一个成功拿到的档位。")
        }
    }
}

// MARK: - 结果行

private struct WellLXPlatformResultRow: View {
    let result: WellLXPlatformTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stateIcon
                Text(result.platformName).font(.body.weight(.medium))
                Spacer()
                Text(result.qualityShort)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.state == .success ? Color.green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            if !result.searchedSong.isEmpty {
                Text("命中：\(result.searchedSong)").font(.caption).foregroundStyle(.secondary)
            }
            if let delay = result.delay {
                Text(String(format: "耗时：%.1f 秒", delay)).font(.caption).foregroundStyle(.secondary)
            }
            // ★ 2026-10-16 用户问题5：逐档明细一行一条（原先拼一长串会被截断看不清）
            if !result.qualityDetails.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(result.qualityDetails, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !result.message.isEmpty {
                Text(result.message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch result.state {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .testing:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

#Preview {
    NavigationStack { WellLXSourceTestView() }
}
