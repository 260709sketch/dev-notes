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

    /// 获取歌曲动态封面（MV 短视频），返回视频 URL 或 nil
    /// 基于网易云 weapi 的 song/detail 接口获取 mv id，再获取 mv/url 接口拿到播放地址
    static func songDynamicCover(id: Int) async throws -> String? {
        do {
            // 1. song/detail 获取 mv id
            let detailParams: [String: Any] = ["c": "[{\"id\":\(id)}]"]
            guard let detail = try await weapiJSON(path: "weapi/v3/song/detail", params: detailParams),
                  let songs = detail["songs"] as? [[String: Any]],
                  let song = songs.first,
                  let mvId = song["mv"] as? Int,
                  mvId != 0 else {
                return nil
            }

            // 2. mv/url 获取视频直链
            let mvParams: [String: Any] = [
                "id": mvId,
                "r": 1080,
                "d": 0,
            ]
            guard let mvResp = try await weapiJSON(path: "weapi/mv/url", params: mvParams),
                  let mvData = mvResp["data"] as? [[String: Any]],
                  let first = mvData.first else {
                // fallback: 尝试 mv/detail 的 brs
                let detail2 = try await weapiJSON(path: "weapi/mv/detail", params: ["id": mvId, "r": 1080])
                guard let data2 = detail2?["data"] as? [String: Any],
                      let brs = data2["brs"] as? [String: String] else { return nil }
                for br in ["1080", "720", "480", "240"] {
                    if let u = brs[br] { return u }
                }
                return brs.values.first
            }
            if let url = first["url"] as? String, !url.isEmpty, url != "http://" {
                return url
            }
            if let brs = first["brs"] as? [String: String] {
                for br in ["1080", "720", "480", "240"] {
                    if let u = brs[br] { return u }
                }
                return brs.values.first
            }
            return nil
        } catch {
            // 接口失败时静默返回 nil，不影响主流程
            return nil
        }
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
