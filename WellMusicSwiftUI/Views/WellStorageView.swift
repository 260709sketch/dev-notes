import SwiftUI
import UniformTypeIdentifiers

/// 存储管理页：数据备份（导出 / 恢复）与缓存（图片 / 歌曲 / 歌手主页）管理。
///
/// ★ 2026-10-16 用户问题14：「设置新增存储分组，数据备份和存储移动出来放到存储分组里，
///   数据备份和缓存分开」——本页按 `mode` 拆成两个入口：`缓存管理` 与 `数据备份`。
///
/// 备份内容 = 白名单前缀下的全部 UserDefaults 项（收藏、歌单、播放历史、
/// 歌词偏移、设置项等）；自定义音源脚本不在内（体积大且有单独的导入通道）。
/// 恢复采用**覆盖写回**，重启 App 后全部生效。
struct WellStorageView: View {
    /// 页面模式（拆成两个设置入口）。
    enum Mode {
        /// 缓存管理（歌曲 / 图片 / 歌手主页）
        case cache
        /// 数据备份（导出 / 恢复）
        case backup

        var title: String {
            switch self {
            case .cache: return "缓存管理"
            case .backup: return "数据备份"
            }
        }
    }

    var mode: Mode = .cache

    /// 参与备份的设置键前缀（本项目自定义键都在这几个前缀下）。
    private static let backupPrefixes = ["favorites.", "playlists.", "lyric", "player.", "wellmusic."]

    /// ★ 2026-10-16 用户问题20：这些键**永不备份** —— Cookie/账号是设备私密凭据
    ///   （换机恢复反而会造成登录态错乱）；内置音源开关后续会隐藏，不随备份走。
    private static let backupExcludedKeys: Set<String> = [
        "wellmusic.netease.account",
        MusicURLResolver.builtinSourceKey,
    ]

    /// 是否为排除项（含网易云账号/Cookie 类前缀兜底）。
    private static func isExcluded(_ key: String) -> Bool {
        if backupExcludedKeys.contains(key) { return true }
        let sensitivePrefixes = ["wellmusic.netease.", "netease."]
        return sensitivePrefixes.contains { key.hasPrefix($0) }
    }

    @State private var exportingURL: URL?
    @State private var showingExporter = false
    /// 自建文档选择器（UIDocumentPicker asCopy；fileImporter 在部分场景点击无响应）
    @State private var showingImportPicker = false
    @State private var pendingRestore: [String: Any]?
    @State private var alertMessage = ""
    @State private var showingAlert = false

    @State private var audioCacheSize: String = "计算中…"
    @State private var artworkCacheSize: String = "计算中…"
    @State private var artistCacheSize: String = "计算中…"
    @State private var artistCacheCount: Int = 0
    @State private var totalCacheText: String = "计算中…"
    @State private var limitText: String = "—"

    var body: some View {
        List {
            switch mode {
            case .backup:
                backupSections
            case .cache:
                cacheSections
            }
        }
        .navigationTitle(mode.title)
        .task {
            // ★ 2026-10-16 用户截图（合计 4.05GB > 上限 4GB）：进页先触发一次预算
            //   检查（淘汰到 95% 上限），再读数 —— 页面数字 = 检查后的口径。
            if mode == .cache {
                await CacheBudget.enforce()
            }
            await refreshCacheSizes()
        }
        .sheet(isPresented: $showingExporter) {
            if let url = exportingURL {
                ShareSheetView(items: [url])
            }
        }
        .fullScreenCover(isPresented: $showingImportPicker) {
            WellBackupDocumentPicker(
                onPick: { url in
                    showingImportPicker = false
                    handleImport(url)
                },
                onCancel: { showingImportPicker = false }
            )
            .ignoresSafeArea()
        }
        .alert("提示", isPresented: $showingAlert) {
            if pendingRestore != nil {
                Button("恢复", role: .destructive) { performRestore() }
                Button("取消", role: .cancel) { pendingRestore = nil }
            } else {
                Button("好的", role: .cancel) {}
            }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - 数据备份

    @ViewBuilder
    private var backupSections: some View {
        Section {
            Button {
                makeBackup()
            } label: {
                Label("导出数据备份", systemImage: "square.and.arrow.up")
            }
            Button {
                showingImportPicker = true
            } label: {
                Label("从备份文件恢复", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("数据备份")
        } footer: {
            Text("备份包含收藏、歌单、播放历史、歌词偏移与全部设置项。恢复后将覆盖当前数据，重启 App 生效。")
                .font(.system(size: 12))
        }
    }

    // MARK: - 缓存管理

    @ViewBuilder
    private var cacheSections: some View {
        Section {
            HStack {
                Text("合计占用")
                Spacer()
                Text(totalCacheText).foregroundStyle(.secondary)
            }
            HStack {
                Text("上限")
                Spacer()
                Text(limitText).foregroundStyle(.secondary)
            }
        } header: {
            Text("缓存总览")
        } footer: {
            Text("上限在「设置 → 存储 → 缓存上限」调整；歌曲、图片、歌手主页三类缓存**合计**超出上限时，自动按「最旧未使用」优先清理。")
                .font(.system(size: 12))
        }

        Section {
            HStack {
                Text("歌曲缓存")
                Spacer()
                Text(audioCacheSize).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                AudioCacheManager.shared.clear()
                Task { await refreshCacheSizes() }
            } label: {
                Label("清除歌曲缓存", systemImage: "trash")
            }

            HStack {
                Text("图片缓存")
                Spacer()
                Text(artworkCacheSize).foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                WellImageCache.shared.clear()
                Task { await refreshCacheSizes() }
            } label: {
                Label("清除图片缓存", systemImage: "trash")

            }

            // ★ 2026-10-16 用户问题15：原来的「歌词缓存」是个已经不再使用的历史目录，
            //   按要求移除，换成**歌手主页缓存**（首次打开歌手主页后，
            //   头像 / 歌曲封面 / 专辑封面与主页数据一起进缓存，有更新时自动覆盖）。
            HStack {
                Text("歌手主页缓存")
                Spacer()
                Text("\(artistCacheSize) · \(artistCacheCount) 位歌手").foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                Task {
                    await WellArtistHomeCache.shared.clear()
                    await refreshCacheSizes()
                }
            } label: {
                Label("清除歌手主页缓存", systemImage: "trash")
            }
        } header: {
            Text("缓存")
        } footer: {
            Text("歌曲缓存为播放过的音频本地副本；图片缓存为封面、头像等网络图片的本地副本；歌手主页缓存保存打开过的歌手主页内容（含头像与专辑封面），再次进入无需等待。")
                .font(.system(size: 12))
        }
    }

    // MARK: - 导出

    private func makeBackup() {
        let defaults = UserDefaults.standard
        var payload: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard Self.backupPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            // ★ 2026-10-16 问题20：Cookie/账号与内置音源开关不进备份
            guard !Self.isExcluded(key) else { continue }
            payload[key] = encodeValue(value)
        }
        let file: [String: Any] = [
            "app": "WellMusicSwiftUI",
            "version": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "defaults": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys]) else {
            alertMessage = "备份生成失败"
            showingAlert = true
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WellMusic备份-\(formatter.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
            exportingURL = url
            showingExporter = true
        } catch {
            alertMessage = "备份写入失败：\(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func encodeValue(_ value: Any?) -> Any? {
        switch value {
        case let data as Data:
            return ["__data__": data.base64EncodedString()]
        case let date as Date:
            return ["__date__": date.timeIntervalSince1970]
        case let values as [Any]:
            return values.map { encodeValue($0) ?? NSNull() }
        case let dict as [String: Any]:
            return dict.mapValues { encodeValue($0) ?? NSNull() }
        default:
            return value
        }
    }

    // MARK: - 恢复

    private func handleImport(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultsPayload = root["defaults"] as? [String: Any] else {
            alertMessage = "备份文件解析失败"
            showingAlert = true
            return
        }
        pendingRestore = defaultsPayload
        alertMessage = "将恢复 \(defaultsPayload.count) 项数据并覆盖当前内容，确认继续？（重启 App 后生效）"
        showingAlert = true
    }

    private func performRestore() {
        guard let payload = pendingRestore else { return }
        let defaults = UserDefaults.standard
        var restored = 0
        for (key, value) in payload {
            guard Self.backupPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            // 恢复侧同样排除 Cookie/账号与内置音源开关（老备份文件也防一手）
            guard !Self.isExcluded(key) else { continue }
            if let decoded = decodeValue(value) {
                defaults.set(decoded, forKey: key)
                restored += 1
            }
        }
        pendingRestore = nil
        alertMessage = "已恢复 \(restored) 项数据，请重启 App 使其全部生效"
        showingAlert = true
    }

    private func decodeValue(_ value: Any) -> Any? {
        if let dict = value as? [String: Any] {
            if let b64 = dict["__data__"] as? String { return Data(base64Encoded: b64) }
            if let ts = dict["__date__"] as? Double { return Date(timeIntervalSince1970: ts) }
            return dict.mapValues { decodeValue($0) ?? NSNull() }
        }
        if let values = value as? [Any] { return values.map { decodeValue($0) ?? NSNull() } }
        if value is NSNull { return nil }
        return value
    }

    // MARK: - 缓存

    private func refreshCacheSizes() async {
        let usage = await CacheBudget.totalUsage()
        audioCacheSize = Self.formatBytes(Int(usage.audio))
        artworkCacheSize = Self.formatBytes(Int(usage.image))
        artistCacheSize = Self.formatBytes(Int(usage.artist))
        artistCacheCount = WellArtistHomeCache.shared.cachedCount()
        totalCacheText = Self.formatBytes(Int(usage.audio + usage.image + usage.artist))
        limitText = Self.formatBytes(Int(AudioCacheManager.byteLimit))
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// 备份文件选择器：`UIDocumentPickerViewController`（asCopy: true）。
/// `asCopy` 会把文件复制到 App 沙盒再回调，规避 iCloud / 第三方文件提供商
/// 的权限确认导致「点击文件没反应」。
struct WellBackupDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: WellBackupDocumentPicker
        init(_ parent: WellBackupDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

/// 极简系统分享包装（UIActivityViewController），用于导出备份文件。
struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
