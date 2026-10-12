import SwiftUI

/// 搜索结果卡片展开页：拉取歌手 / 专辑 / 歌单对应的歌曲列表。
struct WellSearchDetailView: View {
    /// ⚠️ 刻意**不用** `@EnvironmentObject`：`PlayerCore` 每 0.05s 推一次 `currentTime`，
    /// 只要订阅了它，本页 `body` 就跟着每秒重算 20 次 —— 页面里有几十张卡时滚动直接卡死。
    /// 本页只在点击时**发起播放**、不显示任何播放状态，所以直接取单例，不订阅。
    private var player: PlayerCore { PlayerCore.shared }
    let source: WellSearchDetailSource
    var coverURL: String?

    @State private var tracks: [MusicItem] = []
    @State private var albums: [WellAlbumSummary] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty && albums.isEmpty {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView("暂无歌曲", systemImage: "music.note",
                                           description: Text("该内容暂无可播放的歌曲"))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                        Text("暂无歌曲").font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    Section {
                        header
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    // 歌手主页：专辑货架（目前只有网易云提供歌手专辑接口）
                    if !albums.isEmpty {
                        Section("专辑") {
                            ForEach(albums) { album in
                                NavigationLink {
                                    WellSearchDetailView(
                                        source: .album(id: album.id, platform: album.platform, name: album.name, artist: album.artistName),
                                        coverURL: album.picURL)
                                } label: {
                                    HStack(spacing: 12) {
                                        WellRemoteImage(url: album.picURL, displaySize: 56)
                                            .frame(width: 56, height: 56)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(album.name)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                            Text(album.artistName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !tracks.isEmpty {
                        Section(albums.isEmpty ? "歌曲" : "热门歌曲") {
                            ForEach(tracks) { item in
                                TrackRow(item: item)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        player.play(queue: tracks, startIndex: tracks.firstIndex(of: item) ?? 0)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            WellRemoteImage(url: coverURL)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(source.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                Text("\(source.platform.displayName) · \(tracks.count) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    guard !tracks.isEmpty else { return }
                    player.play(queue: tracks, startIndex: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(AppTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        isLoading = true
        tracks = await SearchService.shared.detailTracks(for: source)

        // 歌手主页补充专辑货架（网易云：api/artist/albums 明文可用）
        if case .artist(let artistId, let platform, _) = source, platform == .netease {
            albums = (try? await NeteaseMusicAPI.shared.artistAlbums(id: artistId)) ?? []
        }

        isLoading = false
    }
}