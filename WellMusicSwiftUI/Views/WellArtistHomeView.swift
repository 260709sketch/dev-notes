import SwiftUI

/// 歌手主页 —— 界面结构对齐 Beans `ArtistHomeSheet`，代码按本项目架构重写。
///
/// 结构：Header（72pt 圆形头像 + 名字 + 统计）
/// → 热门歌曲（序号前 3 高亮 / 40pt 封面 / 歌名 + VIP / 专辑名，播放全部按钮，页内搜索过滤）
/// → 专辑 / EP 与单曲 两个横滑货架（160pt 封面 + 名称 + 类型注记）。
///
/// 数据：`artistTopSongs`（热门歌曲）+ `artistAlbums`（专辑，带类型）。
/// 专辑点击 → 歌单页样式详情（WellPlaylistDetailView）。
struct WellArtistHomeView: View {
    let artistId: String
    let artistName: String
    var coverURL: String?

    @State private var resolvedName: String = ""
    @State private var resolvedCover: String?
    @State private var hotSongs: [MusicItem] = []
    @State private var albums: [WellAlbumSummary] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var searchText = ""

    /// 热门歌曲过滤（只影响显示，点击后的队列仍按完整顺序走）
    private var displayedHotSongs: [MusicItem] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return hotSongs }
        return hotSongs.filter { item in
            item.title.lowercased().contains(kw)
                || (item.artist ?? "").lowercased().contains(kw)
                || (item.album ?? "").lowercased().contains(kw)
        }
    }

    private var studioAlbums: [WellAlbumSummary] { albums.filter { !$0.isEPOrSingle } }
    private var epsAndSingles: [WellAlbumSummary] { albums.filter(\.isEPOrSingle) }

    var body: some View {
        Group {
            if isLoading && hotSongs.isEmpty && albums.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed && hotSongs.isEmpty && albums.isEmpty {
                retryState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        artistHeader
                        hotSongsSection
                        albumsSection
                        Color.clear.frame(height: 170)
                    }
                    .padding(.top, 6)
                }
            }
        }
        .navigationTitle("歌手主页")
        .navigationBarTitleDisplayMode(.inline)
        // 页内搜索（挂在导航栏下方，常驻显示，过滤热门歌曲）
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索歌手歌曲")
        .task {
            guard hotSongs.isEmpty && albums.isEmpty else { return }
            await load()
        }
    }

    // MARK: - Header

    private var artistHeader: some View {
        HStack(spacing: 14) {
            WellRemoteImage(url: resolvedCover ?? coverURL, displaySize: 72)
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                .background(Color.secondary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(resolvedName.isEmpty ? artistName : resolvedName)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text("热门歌曲 \(hotSongs.count) 首 · 专辑 \(albums.count) 张")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 热门歌曲

    private var hotSongsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("热门歌曲")
                .font(.system(size: 17, weight: .bold))
                .padding(.horizontal, 16)

            if !hotSongs.isEmpty {
                // 播放全部（长条胶囊，Beans 同款布局）
                Button {
                    guard !displayedHotSongs.isEmpty else { return }
                    PlayerCore.shared.play(queue: displayedHotSongs, startIndex: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(AppTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }

            if hotSongs.isEmpty {
                Text("暂无歌曲")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else if displayedHotSongs.isEmpty {
                Text("没有匹配的歌曲")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayedHotSongs.enumerated()), id: \.element.id) { index, item in
                        Button {
                            PlayerCore.shared.play(queue: displayedHotSongs, startIndex: index)
                        } label: {
                            hotSongRow(index: index, item: item)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 热门歌曲行：`[序号(前3高亮)] [封面40] 歌名+VIP / 专辑名`
    private func hotSongRow(index: Int, item: MusicItem) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(index < 3 ? AppTheme.accent : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 32, alignment: .trailing)

            WellRemoteImage(url: item.albumCoverURL, displaySize: 40)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if item.isVip {
                        WellVipBadge()
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text(item.album ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    // MARK: - 专辑（两个货架：专辑 / EP 与单曲）

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            albumShelf(title: "专辑", albums: studioAlbums)
            albumShelf(title: "EP 与单曲", albums: epsAndSingles)
        }
    }

    @ViewBuilder
    private func albumShelf(title: String, albums: [WellAlbumSummary]) -> some View {
        if !albums.isEmpty {
            WellShelf(title: title, rowHeight: 230) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                    NavigationLink {
                        WellPlaylistDetailView(
                            source: .album(id: album.id, platform: .netease,
                                           name: album.name, artist: album.artistName),
                            coverURL: album.picURL,
                            creatorName: album.artistName)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            WellRemoteImage(url: album.picURL, displaySize: 160)
                                .frame(width: 160, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(album.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(width: 160, alignment: .leading)
                            Text(album.albumType ?? "专辑")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 160, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(WellCardEntrance(index: index, itemID: "artist-album-\(album.id)"))
                }
            }
        }
    }

    // MARK: - 状态与加载

    private var retryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("歌手信息加载失败")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await load() }
            } label: {
                Text("重新加载")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(AppTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = true
        failed = false

        // 并发拉热门歌曲 + 专辑（真实接口）；热门歌曲只取前 50 首
        async let songsTask = try? NeteaseMusicAPI.shared.artistTopSongs(id: artistId)
        async let albumsTask = try? NeteaseMusicAPI.shared.artistAlbums(id: artistId, limit: 50)

        let songs = await songsTask ?? []
        let fetchedAlbums = await albumsTask ?? []

        hotSongs = Array(songs.prefix(50))
        albums = fetchedAlbums
        if resolvedName.isEmpty { resolvedName = artistName }
        if resolvedCover == nil { resolvedCover = coverURL ?? songs.first?.albumCoverURL }

        // 热门歌曲兜底：接口异常时用同名搜索补全（同样封顶 50 首）
        if hotSongs.isEmpty {
            hotSongs = await SearchService.shared
                .search(keyword: artistName, platform: .netease, type: .songs, limit: 50).songs
        }

        failed = hotSongs.isEmpty && albums.isEmpty
        isLoading = false
    }
}

#Preview {
    // 触发构建
    NavigationStack {
        WellArtistHomeView(artistId: "6452", artistName: "示例歌手")
    }
}
