import SwiftUI
import UniformTypeIdentifiers

/// 存储管理页：数据备份（导出 / 恢复）与缓存（图片 / 歌词）管理。
///
/// 备份内容 = 白名单前缀下的全部 UserDefaults 项（收藏、歌单、播放历史、
/// 歌词偏移、设置项等）；自定义音源脚本不在内（体积大且有单独的导入通道）。
/// 恢复采用**覆盖写回**，重启 App 后全部生效。
struct WellStorageView: View {
    /// 参与备份的设置键前缀（本项目自定义键都在这几个前缀下）。
    private static let backupPrefixes = ["favorites.", "playlists.", "lyric", "player.", "wellmusic."]

    @State private var exportingURL: URL?
    @State private var showingExporter = false
    /// 自建文档选择器（UIDocumentPicker asCopy；fileImporter 在部分场景点击无响应）
    @State private var showingImportPicker = false
    @State private var pendingRestore: [String: Any]?
    @State private var alertMessage = ""
    @State private var showingAlert = false

    @State private var artworkCacheSize: String = "计算中…"
    @State private var lyricCacheSize: String = "计算中…"

    var body: some View {
        List {
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

            Section {
                HStack {
                    Text("图片缓存")
                    Spacer()
                    Text(artworkCacheSize).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    WellImageCache.shared.clear()
                    refreshCacheSizes()
                } label: {
                    Label("清除图片缓存", systemImage: "trash")
                }
                HStack {
                    Text("歌词缓存")
                    Spacer()
                    Text(lyricCacheSize).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    clearLyricCache()
                    refreshCacheSizes()
                } label: {
                    Label("清除歌词缓存", systemImage: "trash")
                }
            } header: {
                Text("缓存")
            } footer: {
                Text("图片缓存为封面等网络图片的本地副本；歌词缓存为历史版本遗留的在线歌词副本（已不再使用），可安全清除。")
                    .font(.system(size: 12))
            }
        }
        .navigationTitle("存储与备份")
        .task { refreshCacheSizes() }
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

    // MARK: - 导出

    private func makeBackup() {
        let defaults = UserDefaults.standard
        var payload: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard Self.backupPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
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

    private func refreshCacheSizes() {
        artworkCacheSize = Self.formatBytes(Int(WellImageCache.shared.diskUsage()))
        lyricCacheSize = Self.formatBytes(Self.directorySize(Self.lyricCacheDirectory))
    }

    private func clearLyricCache() {
        let fm = FileManager.default
        if let dir = Self.lyricCacheDirectory,
           let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }
    }

    private static var lyricCacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("amll-ttml", isDirectory: true)
    }

    private static func directorySize(_ url: URL?) -> Int {
        guard let url,
              let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(0) { partial, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + size
        }
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
