import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 自定义音源管理：导入（链接 / 粘贴脚本 / 文件）、激活、优先设置、音源测试。
struct WellLXSourceManageView: View {
    @ObservedObject private var store = WellLXSourceStore.shared

    @State private var urlInput = ""
    @State private var scriptInput = ""
    @State private var importing = false
    @State private var showScriptSheet = false
    @State private var showFilePicker = false
    @State private var importError: String?
    @State private var testingIDs = Set<String>()

    var body: some View {
        Form {
            currentStatusSection
            importSection
            sourceListSection
        }
        // 与其它页面统一底色（同 SettingsView 的说明）
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("自定义音源")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await store.bootstrapIfNeeded() }
        .fullScreenCover(isPresented: $showFilePicker) {
            WellScriptDocumentPicker(
                onPick: { url in
                    showFilePicker = false
                    handlePickedFile(url)
                },
                onCancel: { showFilePicker = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showScriptSheet) {
            WellScriptInputSheet(script: $scriptInput) {
                Task { await importFromScript() }
            }
        }
    }

    // MARK: 当前状态

    private var currentStatusSection: some View {
        Section {
            HStack {
                Label("当前音源", systemImage: "music.note")
                Spacer()
                if store.isInitializing {
                    ProgressView()
                } else if let active = store.activeSource {
                    Text(active.name).foregroundStyle(.secondary)
                } else {
                    Text("未启用").foregroundStyle(.secondary)
                }
            }
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: 导入

    private var importSection: some View {
        Section("导入音源") {
            Text("仅支持 LX 音源格式（.js 脚本）")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("粘贴音源链接（raw .js / GitHub 链接）", text: $urlInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    Task { await importFromURL() }
                } label: {
                    if importing { ProgressView() } else { Text("导入") }
                }
                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty || importing)
            }

            Button {
                scriptInput = ""
                showScriptSheet = true
            } label: {
                Label("粘贴脚本文本导入", systemImage: "doc.on.clipboard")
            }

            Button {
                showFilePicker = true
            } label: {
                Label("从文件导入（.js）", systemImage: "folder")
            }

            if let importError {
                Text(importError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: 音源列表

    private var sourceListSection: some View {
        Section {
            if store.sources.isEmpty {
                Text("还没有导入任何音源").foregroundStyle(.secondary)
            }
            ForEach(store.sources) { source in
                WellLXSourceRow(
                    source: source,
                    isActive: source.id == store.activeSourceID,
                    isTesting: testingIDs.contains(source.id),
                    onToggle: { toggle(source) },
                    onTest: { runTest(source) }
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await store.remove(source) }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                let targets = offsets.map { store.sources[$0] }
                Task {
                    for target in targets { await store.remove(target) }
                }
            }
        } header: {
            Text("已导入音源（\(store.sources.count)）")
        } footer: {
            Text("左滑音源可删除；导入后自动设为优先音源，播放失败时自动换源。")
        }
    }

    // MARK: 动作

    private func toggle(_ source: WellLXSourceInfo) {
        Task {
            if source.id == store.activeSourceID {
                await store.deactivate()
            } else {
                await store.setPriority(source)
                if store.activeSourceID == source.id {
                    // 切换音源后立即用新音源重新解析当前歌曲
                    PlayerCore.shared.reloadCurrentTrack()
                }
            }
        }
    }

    private func runTest(_ source: WellLXSourceInfo) {
        Task {
            testingIDs.insert(source.id)
            await store.test(source)
            testingIDs.remove(source.id)
        }
    }

    private func importFromURL() async {
        importing = true
        importError = nil
        do {
            try await store.importFromURL(urlInput)
            urlInput = ""
        } catch {
            importError = error.localizedDescription
        }
        importing = false
    }

    private func importFromScript() async {
        importError = nil
        do {
            try await store.importScript(scriptInput)
            showScriptSheet = false
        } catch {
            importError = error.localizedDescription
        }
    }

    private func handlePickedFile(_ url: URL) {
        do {
            let script = try String(contentsOf: url, encoding: .utf8)
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                importError = "文件内容为空"
                return
            }
            importError = nil
            Task {
                do {
                    try await store.importScript(script)
                } catch {
                    importError = "导入失败：\(error.localizedDescription)"
                }
            }
        } catch {
            importError = "无法读取文件：\(error.localizedDescription)"
        }
    }
}

// MARK: - 音源行

private struct WellLXSourceRow: View {
    let source: WellLXSourceInfo
    let isActive: Bool
    let isTesting: Bool
    let onToggle: () -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.body)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                testBadge
            }
            HStack(spacing: 12) {
                Button(isActive ? "取消优先" : "设为优先", action: onToggle)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(action: onTest) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("测试", systemImage: "stethoscope")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !source.version.isEmpty { parts.append("v\(source.version)") }
        if !source.author.isEmpty { parts.append(source.author) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var testBadge: some View {
        switch source.testStatus {
        case .working:
            HStack(spacing: 4) {
                ForEach(["wy", "tx", "kg"], id: \.self) { platform in
                    if source.platformTestResults[platform] == true {
                        platformTag(platform, ok: true)
                    }
                }
                if !source.platformTestResults.values.contains(true) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
        case .failed:
            HStack(spacing: 4) {
                ForEach(["wy", "tx", "kg"], id: \.self) { platform in
                    if source.platformTestResults[platform] == false {
                        platformTag(platform, ok: false)
                    }
                }
                if source.platformTestResults.isEmpty {
                    Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
                }
            }
        default:
            EmptyView()
        }
    }

    private func platformTag(_ platform: String, ok: Bool) -> some View {
        Text(Self.label(for: platform))
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(ok ? Color.green : Color.red))
    }

    private static func label(for platform: String) -> String {
        switch platform {
        case "wy": return "网易"
        case "tx": return "QQ"
        case "kg": return "酷狗"
        default: return platform
        }
    }
}

// MARK: - 文件选择器（复制模式，无需 security-scoped）

private struct WellScriptDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .plainText, .item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: WellScriptDocumentPicker
        init(_ parent: WellScriptDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

// MARK: - 粘贴脚本

private struct WellScriptInputSheet: View {
    @Binding var script: String
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $script)
                .font(.system(.footnote, design: .monospaced))
                .padding(8)
                .navigationTitle("粘贴音源脚本")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入", action: onImport)
                            .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

#Preview {
    NavigationStack { WellLXSourceManageView() }
}