import Foundation
import SwiftUI

// MARK: - NeteaseAPI (Dynamic Cover)
enum NeteaseAPI {
    private static let commonHeaders = [
        "Referer": "https://music.163.com/",
        "Origin": "https://music.163.com",
    ]

    /// 发起 weapi 请求并解析 JSON
    private static func weapiJSON(path: String, params: [String: Any]) async throws -> [String: Any]? {
        let url = "https://music.163.com/\(path)"
        let body = NeteaseCrypto.makeBody(params)
        guard let data = body.data(using: .utf8) else { return nil }
        let resp = try await NetworkClient.shared.postRaw(url, body: data,
                                                          contentType: "application/x-www-form-urlencoded",
                                                          headers: commonHeaders)
        return NetworkClient.jsonObject(resp.data)
    }

    /// 获取歌曲动态封面，返回视频直链或 nil。
    ///
    /// ⚠️ 通道说明（实测 2026-10）：该数据走网易云 **eapi** 接口
    /// `/api/songplay/dynamic-cover` —— weapi 通道对它恒返回 500，
    /// 而旧实现（weapi song/detail 取 mv id → weapi mv/url）因 weapi 通道
    /// 整体停用 + mv/url 404 而永远拿不到数据。eapi 需要**登录 Cookie**。
    /// 无动态封面的歌曲接口正常返回但无 videoPlayUrl，此时回退静态封面。
    ///
    /// - Parameter songId: 网易云**歌曲真实 id**（`Track.platformSongId`）。
    ///   ⚠️ 不能用 `Track.id` —— 那是 keyOf 的稳定哈希，不是平台歌曲 id。
    static func songDynamicCover(songId: String) async throws -> String? {
        let cookie = NeteaseSession.shared.cookieHeader
        // eapi 接口要求登录态；未登录直接返回（调用方回退静态封面）
        guard !cookie.isEmpty, !songId.isEmpty else { return nil }

        let path = "/api/songplay/dynamic-cover"
        let params: [String: Any] = [
            "songId": songId,
            "csrf_token": NeteaseSession.shared.cookie(named: "__csrf") ?? "",
            "header": NeteaseCrypto.eapiHeaderPayload(cookie: cookie),
        ]
        guard let body = NeteaseCrypto.makeEapiBody(path: path, params: params),
              let bodyData = body.data(using: .utf8) else { return nil }

        let url = "https://interface.music.163.com/eapi\(path)"
        let resp = try await NetworkClient.shared.postRaw(url, body: bodyData,
                                                          contentType: "application/x-www-form-urlencoded",
                                                          headers: [
                                                            "Referer": "https://music.163.com/",
                                                            "Origin": "https://music.163.com",
                                                            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                                                            "Cookie": cookie,
                                                          ])
        guard let json = NetworkClient.jsonObject(resp.data),
              (json["code"] as? Int) == 200,
              let data = json["data"] as? [String: Any],
              let videoURL = data["videoPlayUrl"] as? String,
              !videoURL.isEmpty, videoURL != "http://" else {
            return nil
        }
        return videoURL
    }
}

// MARK: - CommentsView
/// 歌曲评论页 —— **布局与观感照搬 kumone 的 CommentsView**（用户自己的设计）：
/// 白底半屏 sheet、居中标题 +「完成」、热门/最新分段控制、行内「用户名 + 日期 + 赞数」、
/// 行间细分割线、最新页签底部「加载更多」。
/// 数据层仍是本项目的 `CommentsAPI`（多平台回退链）。
struct CommentsView: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss

    @State private var hotComments: [SongComment] = []
    @State private var latestComments: [SongComment] = []
    @State private var total = 0
    @State private var hasMore = false
    @State private var page = 1
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var selectedSegment = 0 // 0=热门, 1=最新

    private let limit = 30

    private var songId: String { track.platformSongId ?? "" }
    private var platform: String { track.sourcePlatform ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏：居中「评论」+ 右上「完成」
            HStack {
                Spacer()
                Text("评论")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button("完成") { dismiss() }
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.blue)
                    .padding(.trailing, 16)
            }
            .padding(.top, 12)
            .padding(.bottom, 12)

            // 分段控制
            Picker("", selection: $selectedSegment) {
                Text("热门评论").tag(0)
                Text("最新评论").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // 评论列表
            Group {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let list = selectedSegment == 0 ? hotComments : latestComments
                    if list.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("暂无评论")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(list) { comment in
                                    CommentRow(comment: comment)
                                    Divider()
                                        .padding(.leading, 16)
                                }
                                if selectedSegment == 1 && hasMore {
                                    Button {
                                        Task { await loadMoreLatest() }
                                    } label: {
                                        if loading {
                                            ProgressView()
                                        } else {
                                            Text("加载更多")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .padding(.vertical, 16)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .preferredColorScheme(.light)
        .task { await load() }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        page = 1
        defer { loading = false }
        guard let result = await CommentsAPI.fetch(platform: platform, songId: songId, page: 1) else {
            errorMessage = "暂时拿不到评论"
            return
        }
        hotComments = result.hot
        latestComments = result.latest
        total = result.total
        hasMore = result.hasMore
    }

    private func loadMoreLatest() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let target = page + 1
        if let result = await CommentsAPI.fetch(platform: platform, songId: songId, page: target) {
            latestComments.append(contentsOf: result.latest)
            total = result.total
            hasMore = result.hasMore
            page = target
        }
    }
}

/// 评论行：头像 + 同一行「用户名 · 日期 · N 赞」+ 内容。
private struct CommentRow: View {
    let comment: SongComment

    private var likedText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let text = formatter.string(from: NSNumber(value: comment.likedCount)) ?? "\(comment.likedCount)"
        return "\(text) 赞"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 头像
            if let avatarURL = comment.avatarURL, !avatarURL.isEmpty {
                WellRemoteImage(url: avatarURL, displaySize: 36)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.gray)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(comment.nickname)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    Text(comment.timeText)
                        .font(.system(size: 12))
                        .foregroundStyle(.gray)
                    Spacer()
                    if comment.likedCount > 0 {
                        Text(likedText)
                            .font(.system(size: 12))
                            .foregroundStyle(.gray)
                    }
                }
                Text(comment.content)
                    .font(.system(size: 15))
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - AddToPlaylistSheet
/// 添加到歌单 sheet（简化实现，显示自建歌单列表）
struct AddToPlaylistSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [Playlist] = []

    var body: some View {
        NavigationView {
            List {
                ForEach(playlists) { playlist in
                    Button {
                        addToPlaylist(playlist)
                    } label: {
                        HStack(spacing: 12) {
                            if let coverURL = playlist.coverURL, let url = URL(string: coverURL) {
                                WellAsyncImage(url: url) {
                                    Color.gray.opacity(0.3)
                                }
                                .frame(width: 48, height: 48)
                                .cornerRadius(6)
                            } else {
                                Color.gray.opacity(0.3)
                                    .frame(width: 48, height: 48)
                                    .cornerRadius(6)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                                Text("\(playlist.tracks.count) 首歌曲")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("添加到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                playlists = AppState.shared.playlists
            }
        }
    }

    private func addToPlaylist(_ playlist: Playlist) {
        let state = AppState.shared
        guard let idx = state.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }

        let src = MusicSource(rawValue: track.sourcePlatform ?? "netease") ?? .netease
        let item = MusicItem(
            source: src,
            title: track.name,
            artist: track.artistNames,
            album: track.album.name,
            albumCoverURL: track.album.picUrl,
            duration: track.duration,
            qqSongMid: track.album.albumMid
        )

        // 避免重复添加
        if !state.playlists[idx].tracks.contains(where: { MusicItem.isSame($0, item) }) {
            state.playlists[idx].tracks.insert(item, at: 0)
        }

        ToastCenter.shared.show("已添加到「\(playlist.name)」")
    }
}

// MARK: - NowPlayingTrackDestinationLinks
/// 歌曲详情页的跳转链接（歌手 / 专辑）。
///
/// ★ 2026-10-14 用户：「所有歌曲播放器界面可以通过点击歌手名字转跳歌手主页，
///   并且多名歌手要能识别弹窗，弹窗要和三个点菜单弹窗一样（系统原生 Menu）」。
///   结构照 kumone 的 `NowPlayingTrackDestinationLinks`：
///   * 单名歌手 → 名字直接可点，跳歌手主页；
///   * 多名歌手 → **原生 Menu** 弹出歌手清单，选谁跳谁，label 显示「A / B」；
///   * 专辑名独立可点（下划线），跳专辑详情。
///
/// ⚠️ 跳转不是就地 push：播放页是 fullScreenCover，自己不在导航栈里。
///   这里只把请求交给 `NowPlayingNavigator`，由 `MainTabView` 关掉播放页后再 push。
struct NowPlayingTrackDestinationLinks: View {
    let track: Track
    let font: Font
    let color: Color
    let onOpenDestination: (NowPlayingDestination) -> Void

    init(track: Track,
         font: Font,
         color: Color,
         onOpenDestination: @escaping (NowPlayingDestination) -> Void) {
        self.track = track
        self.font = font
        self.color = color
        self.onOpenDestination = onOpenDestination
    }

    private var artists: [ArtistRef] {
        track.artists.filter { !$0.name.isEmpty }
    }

    /// 可跳转的歌手（id / mid 至少有一个可用）。
    private var clickableArtists: [(artist: ArtistRef, destination: NowPlayingDestination)] {
        artists.compactMap { artist in
            NowPlayingDestination.artist(from: track, artist: artist)
                .map { (artist, $0) }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            artistsArea

            if let album = NowPlayingDestination.album(from: track) {
                if !artists.isEmpty {
                    Text("—")
                        .font(font)
                        .foregroundStyle(color.opacity(0.75))
                }
                Button {
                    onOpenDestination(album)
                } label: {
                    Text(track.album.name)
                        .font(font)
                        .foregroundStyle(color)
                        .underline()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开专辑：\(track.album.name)")
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var artistsArea: some View {
        let clickable = clickableArtists

        if artists.isEmpty {
            Text(track.artistNames)
                .font(font)
                .foregroundStyle(color)
        } else if clickable.count > 1 {
            // 多名可跳转歌手 → 原生菜单选一个（与播放器三点菜单同一种弹窗）
            Menu {
                ForEach(Array(clickable.enumerated()), id: \.offset) { item in
                    Button(item.element.artist.name) {
                        onOpenDestination(item.element.destination)
                    }
                }
            } label: {
                Text(artists.map(\.name).joined(separator: " / "))
                    .font(font)
                    .foregroundStyle(color)
            }
            .accessibilityLabel("选择歌手")
        } else if let only = clickable.first {
            // 单个可跳转歌手 → 直接点
            Button {
                onOpenDestination(only.destination)
            } label: {
                Text(artists.map(\.name).joined(separator: " / "))
                    .font(font)
                    .foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开歌手：\(only.artist.name)")
        } else {
            Text(artists.map(\.name).joined(separator: " / "))
                .font(font)
                .foregroundStyle(color)
        }
    }
}
