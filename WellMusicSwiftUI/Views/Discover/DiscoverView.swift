import SwiftUI

// MARK: - 视图模型

/// 发现（推荐）页的数据源。
///
/// 这里用到的四个接口（个性化歌单 / 排行榜 / 新碟上架 / 热门歌手）**都无需登录**，
/// 所以未登录也能有完整内容 —— 这点和「每日推荐」「私人漫游」那类登录专属模块
/// 有本质区别，也是本页刻意只做这四块的原因。
@MainActor
final class WellDiscoverViewModel: ObservableObject {
    enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    /// 推荐歌单
    @Published private(set) var playlists: [WellPlaylistSummary] = []
    /// 排行榜（带更新频率）
    @Published private(set) var toplists: [WellToplistSummary] = []
    /// 新碟上架
    @Published private(set) var albums: [WellAlbumSummary] = []
    /// 热门歌手
    @Published private(set) var artists: [WellArtistSummary] = []

    /// 已经成功载入过就不再自动重拉（切 Tab 回来不闪骨架屏）。
    private var hasLoadedOnce = false

    /// 首屏载入。已成功载入过则直接返回。
    func loadIfNeeded() async {
        guard !hasLoadedOnce else { return }
        await load()
    }

    /// 强制重新载入（下拉刷新 / 错误重试）。
    func reload() async {
        hasLoadedOnce = false
        await load()
    }

    private func load() async {
        if !hasLoadedOnce { phase = .loading }

        let api = NeteaseMusicAPI.shared
        // 四路并发：各自失败只影响自己那一块，不拖垮整页
        async let playlistsTask = try? api.personalizedPlaylists(limit: 30)
        async let toplistsTask = try? api.toplists()
        async let albumsTask = try? api.newAlbums(limit: 20)
        async let artistsTask = try? api.topArtists(limit: 30)

        let fetchedPlaylists = await playlistsTask ?? []
        let fetchedToplists = await toplistsTask ?? []
        let fetchedAlbums = await albumsTask ?? []
        let fetchedArtists = await artistsTask ?? []

        playlists = fetchedPlaylists
        toplists = Array(fetchedToplists.prefix(12))
        albums = Array(fetchedAlbums.prefix(20))
        // 热门歌手取前 30 后再打散截取，避免每次都看到同一批面孔
        artists = Array(fetchedArtists.shuffled().prefix(12))

        let nothingAtAll = playlists.isEmpty && toplists.isEmpty
            && albums.isEmpty && artists.isEmpty
        if nothingAtAll {
            // 四路全空时再补一次诊断请求，把真实报错捞出来 ——
            // 之前只显示「网络连接失败」，连是 403、超时还是解码失败都看不出，
            // 排查全靠猜。这里多花一次请求换一个能定位的提示。
            var detail = ""
            do {
                _ = try await api.toplists()
            } catch {
                detail = error.localizedDescription
            }
            phase = .failed(detail.isEmpty ? "网络连接失败，请检查网络后重试" : "加载失败：\(detail)")
        } else {
            hasLoadedOnce = true
            phase = .loaded
        }
    }
}

// MARK: - 发现页

/// 发现 Tab：推荐歌单 / 排行榜 / 新碟上架 / 热门歌手。
///
/// 版式与 kumone 的推荐页保持一致（横向货架 + 同尺寸卡片），
/// 但全部由本项目自己的组件（`WellShelf` / `WellCoverCard` / `WellArtistCard`）搭建。
///
/// ⚠️ 本视图**不带 `NavigationStack`**：导航容器由 `MainTabView` 统一提供。
/// 原因见 `MainTabView.page(_:_:)` —— 四个 Tab 的导航栈同时在视图树中时，
/// 切换可见性会让四个导航栏一起重新测量，大标题与整页都会跳一下。
struct DiscoverView: View {
    @StateObject private var model = WellDiscoverViewModel()

    private var contentInset: CGFloat { WellSearchMetrics.contentInset }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch model.phase {
                case .loading:
                    skeletonBody
                case .failed(let message):
                    failureBody(message)
                case .loaded:
                    loadedBody
                }

                // 底栏（迷你播放器 + Tab 胶囊）留白：约 54 + 8 + 64 + 安全区
                Color.clear.frame(height: 150)
            }
            .padding(.top, 6)
        }
        .background(AppTheme.background)
        .navigationTitle("发现")
        .task { await model.loadIfNeeded() }
        .refreshable { await model.reload() }
    }

    // MARK: 内容

    @ViewBuilder
    private var loadedBody: some View {
        if !model.playlists.isEmpty {
            WellShelf(title: "推荐歌单") {
                ForEach(model.playlists.prefix(12)) { playlist in
                    NavigationLink {
                        WellSearchDetailView(
                            source: .playlist(id: playlist.id, platform: .netease, name: playlist.name),
                            coverURL: playlist.coverURL
                        )
                    } label: {
                        WellCoverCard(
                            coverURL: playlist.coverURL,
                            title: playlist.name,
                            subtitle: playlist.creatorName,
                            playCount: playlist.playCount
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.toplists.isEmpty {
            WellShelf(title: "排行榜") {
                ForEach(model.toplists) { toplist in
                    NavigationLink {
                        WellSearchDetailView(
                            source: .playlist(id: toplist.id, platform: .netease, name: toplist.name),
                            coverURL: toplist.coverURL
                        )
                    } label: {
                        toplistCard(toplist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.albums.isEmpty {
            WellShelf(title: "新碟上架") {
                ForEach(model.albums) { album in
                    NavigationLink {
                        WellSearchDetailView(
                            source: .album(id: album.id, platform: .netease,
                                           name: album.name, artist: album.artistName),
                            coverURL: album.picURL
                        )
                    } label: {
                        WellCoverCard(
                            coverURL: album.picURL,
                            title: album.name,
                            subtitle: album.artistName
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.artists.isEmpty {
            WellShelf(title: "热门歌手") {
                ForEach(model.artists) { artist in
                    NavigationLink {
                        WellSearchDetailView(
                            source: .artist(id: artist.id, platform: .netease, name: artist.name),
                            coverURL: artist.picURL
                        )
                    } label: {
                        WellArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 排行榜卡片

    /// 排行榜卡片：封面 + 底部渐变 + 更新频率。
    ///
    /// 与普通歌单卡片的区别只有这一处 —— 更新频率压在渐变上，
    /// 让「每周更新 / 实时更新」这类信息在封面里就能读到。
    private func toplistCard(_ toplist: WellToplistSummary) -> some View {
        let size = WellSearchMetrics.cardSize
        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                WellRemoteImage(url: toplist.coverURL)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let frequency = toplist.updateFrequency, !frequency.isEmpty {
                    Text(frequency)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(8)
                }
            }
            .frame(width: size, height: size)

            Text(toplist.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: 骨架屏

    private var skeletonBody: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(AppTheme.secondaryBackground)
                        .frame(width: 110, height: 20)
                        .padding(.horizontal, contentInset)

                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 7) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppTheme.secondaryBackground)
                                    .frame(width: WellSearchMetrics.cardSize,
                                           height: WellSearchMetrics.cardSize)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(AppTheme.secondaryBackground)
                                    .frame(width: 104, height: 12)
                            }
                        }
                    }
                    .padding(.leading, contentInset)
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("正在加载推荐内容")
    }

    // MARK: 失败态

    private func failureBody(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.reload() }
            } label: {
                Text("重试")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(AppTheme.secondaryBackground, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 90)
    }
}
