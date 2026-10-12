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
/// 评论页占位（简化实现，显示空状态）
struct CommentsView: View {
    let track: Track

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("评论功能开发中")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("《\(track.name)》")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("评论")
            .navigationBarTitleDisplayMode(.inline)
        }
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
/// 歌曲详情页的跳转链接（艺术家、专辑）
struct NowPlayingTrackDestinationLinks: View {
    let track: Track
    let font: Font
    let color: Color
    let onOpenDestination: (Destination) -> Void

    init(track: Track,
         font: Font,
         color: Color,
         onOpenDestination: @escaping (Destination) -> Void) {
        self.track = track
        self.font = font
        self.color = color
        self.onOpenDestination = onOpenDestination
    }

    var body: some View {
        HStack(spacing: 6) {
            // 艺术家
            ForEach(track.artists, id: \.id) { artist in
                Button {
                    let summary = ArtistSummary(
                        id: artist.id,
                        name: artist.name,
                        picUrl: nil,
                        sourcePlatform: track.sourcePlatform,
                        singerMid: artist.singerMid
                    )
                    if let mid = artist.singerMid {
                        onOpenDestination(.artistWithMid(artist.id, mid, summary))
                    } else {
                        onOpenDestination(.artist(artist.id))
                    }
                } label: {
                    Text(artist.name)
                        .font(font)
                        .foregroundStyle(color)
                }
                .buttonStyle(.plain)
            }

            if !track.artists.isEmpty {
                Text("·")
                    .font(font)
                    .foregroundStyle(.secondary.opacity(0.6))
            }

            // 专辑
            Button {
                let summary = AlbumSummary(
                    id: track.album.id,
                    name: track.album.name,
                    picUrl: track.album.picUrl,
                    sourcePlatform: track.sourcePlatform,
                    albumMid: track.album.albumMid
                )
                if let mid = track.album.albumMid {
                    onOpenDestination(.albumWithMid(track.album.id, mid, summary))
                } else {
                    onOpenDestination(.album(track.album.id))
                }
            } label: {
                Text(track.album.name)
                    .font(font)
                    .foregroundStyle(.secondary)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .lineLimit(1)
    }
}
