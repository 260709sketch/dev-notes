import SwiftUI
import UIKit

/// 歌单导入 —— 从 kumone `PlaylistImportView` 完整移植（该功能为本用户原创，授权全搬）。
///
/// 流程：粘贴歌单链接（支持网易云 / QQ 音乐短链接、网页链接、纯 ID）
/// → 短链接跟随重定向解析 → 正则提取歌单 ID
/// → 平台详情接口拉全量歌曲 → 存入本地歌单 `AppState.playlists`。
///
/// 网易云走本项目现成的 `playlistForImport`（playlistDetail + trackIds 分块 songDetails，
/// 天然支持 1000+ 首大歌单）；QQ 走 `fcg_ucc_getcdinfo_byids_cp.fcg` 手动解析。
struct PlaylistImportView: View {
    enum ImportPlatform: String, CaseIterable, Identifiable {
        case netease = "网易云"
        case qq = "QQ音乐"
        var id: String { rawValue }
    }

    @EnvironmentObject private var appState: AppState

    @State private var platform: ImportPlatform = .netease
    @State private var playlistURL = ""
    @State private var isLoading = false
    @State private var playlistName = ""
    @State private var importedTracks: [MusicItem] = []
    @State private var errorMessage = ""
    @State private var showSuccess = false

    var body: some View {
        Form {
            Section("选择平台") {
                Picker("平台", selection: $platform) {
                    ForEach(ImportPlatform.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("歌单链接") {
                TextField("粘贴歌单链接或输入歌单ID", text: $playlistURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack(spacing: 12) {
                    Button {
                        if let text = UIPasteboard.general.string { playlistURL = text }
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "doc.on.clipboard")
                            Text("粘贴")
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await importPlaylist() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("解析并导入")
                                    .foregroundStyle(AppTheme.accent)
                            }
                            Spacer()
                        }
                    }
                    .disabled(playlistURL.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }
            }

            if !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if !importedTracks.isEmpty {
                Section("已导入 \(importedTracks.count) 首到本地歌单「\(playlistName)」") {
                    ForEach(Array(importedTracks.prefix(20).enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(item.artist ?? "未知歌手")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if importedTracks.count > 20 {
                        Text("... 还有 \(importedTracks.count - 20) 首")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("说明") {
                Text("支持网易云、QQ音乐歌单链接或ID。导入的歌曲会保存到本地歌单，不依赖平台登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("歌单导入")
        .alert("导入成功", isPresented: $showSuccess) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("已成功导入 \(importedTracks.count) 首歌曲到本地歌单「\(playlistName)」")
        }
    }

    // MARK: - 导入主流程（kumone 原创逻辑，授权移植）

    private func importPlaylist() async {
        isLoading = true
        errorMessage = ""
        importedTracks = []

        let input = playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            errorMessage = "请输入歌单链接或ID"
            isLoading = false
            return
        }

        // 先解析短链接（如 163cn.tv），获取真实链接
        var resolvedInput = input
        if let shortURL = extractShortURL(from: input) {
            do {
                resolvedInput = try await resolveShortURL(shortURL)
            } catch {
                errorMessage = "短链接解析失败：\(error.localizedDescription)"
                isLoading = false
                return
            }
        }

        let playlistID = extractPlaylistID(from: resolvedInput)

        do {
            switch platform {
            case .netease:
                try await importNeteasePlaylist(id: playlistID)
            case .qq:
                try await importQQPlaylist(id: playlistID)
            }
        } catch {
            errorMessage = "导入失败：\(error.localizedDescription)"
        }

        isLoading = false
    }

    /// 从输入中提取短链接（163cn.tv / t.cn）
    private func extractShortURL(from input: String) -> String? {
        let patterns = [
            "https?://163cn\\.tv/[a-zA-Z0-9]+",
            "https?://t\\.cn/[a-zA-Z0-9]+",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
               let range = Range(match.range, in: input) {
                return String(input[range])
            }
        }
        return nil
    }

    /// 解析短链接：URLSession 自动跟随重定向，最终 response.url 即真实链接
    private func resolveShortURL(_ shortURL: String) async throws -> String {
        guard let url = URL(string: shortURL) else { return shortURL }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.url?.absoluteString ?? shortURL
    }

    /// 从链接/文本中提取歌单 ID
    /// 网易云：`playlist?id=123456`；QQ：`playlist/123456`；酷狗：`single/123456` 或 `gcid_xxx`
    private func extractPlaylistID(from input: String) -> String {
        let patterns = [
            "[?&]id=(\\d+)",
            "playlist/(\\d+)",
            "single/(\\d+)",
            "(gcid_[a-zA-Z0-9]+)",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
               let range = Range(match.range(at: 1), in: input) {
                return String(input[range])
            }
        }
        if input.allSatisfy({ $0.isNumber }) { return input }
        if input.hasPrefix("gcid_") { return input }
        return input
    }

    // MARK: 网易云

    /// 网易云歌单导入：`playlistForImport` 已内置「详情 + trackIds 分块 songDetails」，
    /// 大歌单不会被 1000 首截断。
    private func importNeteasePlaylist(id: String) async throws {
        let imported = try await NeteaseMusicAPI.shared.playlistForImport(id: id)
        let name = playlistName.isEmpty ? (imported.name.isEmpty ? "导入的歌单" : imported.name) : imported.name
        finishImport(name: name, sourcePlatform: "netease", coverURL: imported.coverURL, tracks: imported.tracks)
    }

    // MARK: QQ 音乐

    /// QQ 音乐歌单导入：`fcg_ucc_getcdinfo_byids_cp.fcg` 公开接口，无需登录。
    private func importQQPlaylist(id: String) async throws {
        let urlStr = "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg"
            + "?type=1&json=1&utf8=1&onlysong=0&disstid=\(id)&format=json"
        guard let url = URL(string: urlStr) else {
            errorMessage = "无效的QQ音乐歌单ID"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cdlist = json["cdlist"] as? [[String: Any]],
              let cd = cdlist.first,
              let songList = cd["songlist"] as? [[String: Any]] else {
            errorMessage = "解析QQ音乐歌单失败"
            return
        }

        let dissName = (cd["dissname"] as? String) ?? ""
        var tracks: [MusicItem] = []
        for item in songList.prefix(500) {
            guard let songmid = item["songmid"] as? String, !songmid.isEmpty else { continue }
            let songname = (item["songname"] as? String) ?? ""
            let interval = (item["interval"] as? Int) ?? 0
            let singers = (item["singer"] as? [[String: Any]]) ?? []
            let artistNames = singers.compactMap { $0["name"] as? String }.joined(separator: "/")
            let albumName = (item["albumname"] as? String) ?? ""
            let albumMid = (item["albummid"] as? String) ?? ""
            let picUrl = albumMid.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(albumMid).jpg"

            tracks.append(MusicItem(
                source: .qq,
                title: songname,
                artist: artistNames.isEmpty ? "未知歌手" : artistNames,
                album: albumName,
                albumCoverURL: picUrl,
                duration: TimeInterval(interval),
                qqSongMid: songmid
            ))
        }

        finishImport(name: dissName.isEmpty ? "导入的QQ音乐歌单" : dissName,
                     sourcePlatform: "qq", coverURL: tracks.first?.albumCoverURL, tracks: tracks)
    }

    // MARK: 落库

    /// 存入本地歌单（`AppState.playlists`，与「我的歌单」共用一套）并展示结果
    @MainActor
    private func finishImport(name: String, sourcePlatform: String, coverURL: String?, tracks: [MusicItem]) {
        playlistName = name
        importedTracks = tracks
        appState.playlists.insert(Playlist(name: name, coverURL: coverURL, tracks: tracks), at: 0)
        showSuccess = true
    }
}

#Preview {
    NavigationStack { PlaylistImportView() }
}
