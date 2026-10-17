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
    @State private var updateCheckingIDs = Set<String>()
    @State private var showSharePicker = false
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    /// 「检查更新」发现新版本后的确认弹窗载荷
    @State private var updatePromptSource: WellLXSourceInfo?
    @State private var updatePromptVersion = ""
    @State private var updatePromptScript = ""
    @State private var showUpdatePrompt = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            currentStatusSection
            importSection
            sourceListSection
        }
        // ★ Form 系统自带背景自动延伸到 chrome 区域下面（理由同 ProfileView），
        //   不写 scrollContentBackground / background，完全交给系统。
        .navigationTitle("自定义音源")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // ★ 2026-10-17 用户：新增「分享音源」——可选当前音源或全部
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSharePicker = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(store.sources.isEmpty)
            }
        }
        .confirmationDialog("分享音源", isPresented: $showSharePicker, titleVisibility: .visible) {
            Button("分享当前音源") {
                if let active = store.activeSource ?? store.sources.first,
                   let file = store.shareFile(for: active) {
                    shareItems = [file]
                    showShareSheet = true
                }
            }
            Button("分享全部音源（\(store.sources.count) 个）") {
                let files = store.shareFilesForAll()
                if !files.isEmpty {
                    shareItems = files
                    showShareSheet = true
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showShareSheet) {
            WellLXShareSheet(items: shareItems)
        }
        .task { await store.bootstrapIfNeeded() }
        .fullScreenCover(isPresented: $showFilePicker) {
            WellScriptDocumentPicker(
                onPick: { urls in
                    showFilePicker = false
                    handlePickedFiles(urls)
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
        .alert("发现新版本 \(updatePromptVersion)", isPresented: $showUpdatePrompt) {
            Button("同步更新") { applyPendingUpdate() }
            Button("取消", role: .cancel) { clearUpdatePrompt() }
        } message: {
            Text("音源「\(updatePromptSource?.name ?? "")」当前版本 \(updatePromptSource?.version ?? "—")，是否用远端最新脚本覆盖本地？")
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
                    isCheckingUpdate: updateCheckingIDs.contains(source.id),
                    onToggle: { toggle(source) },
                    onTest: { runTest(source) },
                    onCheckUpdate: { checkUpdate(source) }
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
            Text("左滑音源可删除；导入后自动设为优先音源，播放失败时自动换源。发现新版本时从底部弹出更新提示。")
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

    // MARK: 更新

    /// 拉取音源脚本声明的 srcUrl，比对版本号（问题11）。
    private func checkUpdate(_ source: WellLXSourceInfo) {
        Task {
            updateCheckingIDs.insert(source.id)
            let result = await store.checkUpdate(for: source)
            updateCheckingIDs.remove(source.id)
            switch result {
            case .unavailable:
                ToastCenter.shared.show("该音源未声明在线更新地址")
            case .failed:
                ToastCenter.shared.show("检查更新失败，请稍后重试")
            case .upToDate:
                ToastCenter.shared.show("已是最新版本（\(source.version)）")
            case .newer(let version, let script):
                updatePromptSource = source
                updatePromptVersion = version
                updatePromptScript = script
                showUpdatePrompt = true
            }
        }
    }

    private func applyPendingUpdate() {
        guard let source = updatePromptSource else { clearUpdatePrompt(); return }
        let script = updatePromptScript
        clearUpdatePrompt()
        Task {
            do {
                try await store.applyUpdate(script, to: source)
                ToastCenter.shared.show("音源「\(source.name)」已更新")
            } catch {
                ToastCenter.shared.show("更新失败：\(error.localizedDescription)")
            }
        }
    }

    private func clearUpdatePrompt() {
        showUpdatePrompt = false
        updatePromptSource = nil
        updatePromptVersion = ""
        updatePromptScript = ""
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

    /// 多选导入（2026-10-15 用户：一次可导入多个音源脚本）。
    private func handlePickedFiles(_ urls: [URL]) {
        importError = nil
        Task {
            var failures: [String] = []
            for url in urls {
                do {
                    let script = try String(contentsOf: url, encoding: .utf8)
                    guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        failures.append("\(url.lastPathComponent)：内容为空")
                        continue
                    }
                    _ = try await store.importScript(script)
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                importError = "部分导入失败：\(failures.joined(separator: "；"))"
            }
        }
    }
}

// MARK: - 文件选择器（复制模式，无需 security-scoped）

// MARK: - 音源行

private struct WellLXSourceRow: View {
    let source: WellLXSourceInfo
    let isActive: Bool
    let isTesting: Bool
    let isCheckingUpdate: Bool
    let onToggle: () -> Void
    let onTest: () -> Void
    let onCheckUpdate: () -> Void

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
                // ★ 2026-10-16 第十轮问题3：删除「测试」按钮（测试统一走音源测试页）
                Button(action: onCheckUpdate) {
                    if isCheckingUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        // ★ 2026-10-16 用户：检查更新按钮不要图标
                        Text("检查更新")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            // ★ 2026-10-16 用户问题1：每音源「更新提示」开关移除
            //   （启动自动检查已由高级功能的全局开关统一控制，这里的单项开关只会让人困惑）
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

private struct WellScriptDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .plainText, .item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        // 多选导入：一次可挑多个音源脚本
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: WellScriptDocumentPicker
        init(_ parent: WellScriptDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            parent.onPick(urls)
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

/// 系统分享面板包装（UIActivityViewController）
private struct WellLXShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
