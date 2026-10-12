import SwiftUI

/// 歌单导入：粘贴网易云 / QQ 音乐的歌单分享链接（或纯数字 ID），
/// 解析后把整张歌单存进本地「自建歌单」。
///
/// 交互形态对齐 kumone 设置页里的歌单导入（用户指定参考），实现是本项目自己的：
/// 短链（163cn.tv）跟随重定向拿真实链接 → 正则提取歌单 ID → 按平台走各自的
/// 明文接口 → 写入 `AppState.playlists`，不依赖平台登录态。
struct PlaylistImportView: View {
    enum ImportPlatform: String, CaseIterable, Identifiable {
        case netease = "网易云"
        case qq = "QQ音乐"
        var id: String { rawValue }
    }

    struct ImportResult {
        var name: String
        var tracks: [MusicItem]
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var platform: ImportPlatform = .netease
    @State private var linkText = ""
    @State private var isImporting = false
    @State private var errorMessage = ""
    @State private var result: ImportResult?
    @State private var showSuccess = false

    var body: some View {
        Form {
            platformSection
            linkSection

            if !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let result {
                importedSection(result)
            }

            Section {
                Text("支持网易云、QQ音乐歌单的分享链接或纯数字 ID。导入后保存为本地歌单，播放时按歌曲平台正常解析音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("歌单导入")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        // 分组表单页照 kumone Playlist 的写法：底色按主题显式切换，与 nav bar 连续
        .background(colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
        .alert("导入成功", isPresented: $showSuccess) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("「\(result?.name ?? "歌单")」共 \(result?.tracks.count ?? 0) 首已保存到本地歌单")
        }
    }

    // MARK: 分区

    private var platformSection: some View {
        Section("平台") {
            Picker("平台", selection: $platform) {
                ForEach(ImportPlatform.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var linkSection: some View {
        Section("歌单链接") {
            TextField("粘贴分享链接或输入歌单 ID", text: $linkText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack(spacing: 12) {
                Button {
                    pasteFromClipboard()
                } label: {
                    HStack {
                        Spacer()
                        Label("粘贴", systemImage: "doc.on.clipboard")
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await importPlaylist() }
                } label: {
                    HStack {
                        Spacer()
                        if isImporting {
                            ProgressView()
                        } else {
                            Text("解析并导入")
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty || isImporting)
            }
        }
    }

    private func importedSection(_ result: ImportResult) -> some View {
        Section("已导入「\(result.name)」· \(result.tracks.count) 首") {
            ForEach(Array(result.tracks.prefix(20).enumerated()), id: \.offset) { index, track in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(track.artist ?? "未知歌手")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if result.tracks.count > 20 {
                Text("…还有 \(result.tracks.count - 20) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 动作

    private func pasteFromClipboard() {
        if let text = UIPasteboard.general.string {
            linkText = text
        }
    }

    private func importPlaylist() async {
        let input = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            errorMessage = "请输入歌单链接或 ID"
            return
        }

        isImporting = true
        errorMessage = ""
        result = nil
        defer { isImporting = false }

        // 网易云分享文案常带短链（163cn.tv），先跟随重定向换成真实链接再提取 ID。
        var working = input
        if let short = extractShortURL(from: input) {
            do {
                working = try await resolveShortURL(short)
            } catch {
                errorMessage = "短链接解析失败：\(error.localizedDescription)"
                return
            }
        }

        let id = extractPlaylistID(from: working)
        do {
            switch platform {
            case .netease:
                let imported = try await NeteaseMusicAPI.shared.playlistForImport(id: id)
                let playlist = Playlist(
                    name: imported.name.isEmpty ? "导入的歌单" : imported.name,
                    coverURL: imported.coverURL,
                    tracks: imported.tracks
                )
                save(playlist)
                result = ImportResult(name: playlist.name, tracks: imported.tracks)
                showSuccess = true
            case .qq:
                let imported = try await QQMusicAPI.shared.playlistDetail(dissTid: id)
                let playlist = Playlist(
                    name: imported.name.isEmpty ? "导入的QQ音乐歌单" : imported.name,
                    coverURL: imported.coverURL,
                    tracks: imported.tracks
                )
                save(playlist)
                result = ImportResult(name: playlist.name, tracks: imported.tracks)
                showSuccess = true
            }
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 存进本地自建歌单（最新在前）。
    private func save(_ playlist: Playlist) {
        appState.playlists.insert(playlist, at: 0)
    }

    // MARK: 链接解析

    /// 从输入里找短链（网易云分享的 163cn.tv / 微博 t.cn）。
    private func extractShortURL(from input: String) -> String? {
        let patterns = [
            "https?://163cn\\.tv/[a-zA-Z0-9]+",
            "https?://t\\.cn/[a-zA-Z0-9]+",
        ]
        let range = NSRange(input.startIndex..., in: input)
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: input, range: range),
               let matchRange = Range(match.range, in: input) {
                return String(input[matchRange])
            }
        }
        return nil
    }

    /// URLSession 自动跟随重定向，最终 `response.url` 就是真实链接。
    private func resolveShortURL(_ shortURL: String) async throws -> String {
        guard let url = URL(string: shortURL) else { return shortURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
                         forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.url?.absoluteString ?? shortURL
    }

    /// 从链接或纯文本里提取歌单 ID。
    ///
    /// 覆盖：
    /// * `https://music.163.com/#/playlist?id=123456`
    /// * `https://y.qq.com/n/ryqq/playlist/123456`
    /// * `https://www.kugou.com/yy/special/single/123456.html`（备用）
    /// * 纯数字 / gcid_ 格式直接当 ID 用
    private func extractPlaylistID(from input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        let patterns = [
            "[?&]id=(\\d+)",
            "playlist/(\\d+)",
            "single/(\\d+)",
            "(gcid_[a-zA-Z0-9]+)",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: input, range: range),
               match.numberOfRanges > 1,
               let idRange = Range(match.range(at: 1), in: input) {
                return String(input[idRange])
            }
        }
        return input
    }
}
