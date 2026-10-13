import SwiftUI

/// 发现页（首页）—— 对齐 Beans 的发现页板块，代码按本项目架构重写。
///
/// 板块（自上而下）：
/// 1. `dailySection`  每日推荐：横滑入口卡（每日推荐 / 私人漫游 / 心动模式）
/// 2. `newAlbumsSection` 新碟上架：横滑专辑卡
/// 3. `toplistsSection` 排行榜：竖排榜单行
/// 4. `artistsSection` 热门歌手：圆形横滑
///
/// ⚠️ 性能铁律：本页**绝不订阅 PlayerCore**。整页是长列表 + 异步图片，
///    一旦订阅 20Hz 的 `currentTime`，整页每秒重算 20 次 → 滑动必掉帧。
///    发起播放只用 `PlayerCore.shared` 单例，不做订阅。
///
/// ⚠️ 导航栏：本页自带 `NavigationStack`，**不手动铺背景**（除 ScrollView 兜底色），
///    以对齐 iOS 26 系统 chrome 的渲染方式（参见项目白边终审结论）。
struct DiscoverView: View {
    @State private var dailySongs: [MusicItem] = []
    @State private var recommendedPlaylists: [WellPlaylistSummary] = []
    @State private var newAlbums: [WellAlbumSummary] = []
    @State private var toplists: [WellToplistSummary] = []
    @State private var artists: [WellArtistSummary] = []

    @State private var isLoading = true
    @State private var errorMessage: String?
    /// 正在加载的动作键（私人漫游 / 心动模式），用于按钮转圈
    @State private var actionLoading: String?

    var body: some View {
        // ⚠️ 不带 NavigationStack：导航容器由 MainTabView 的 page() 统一提供（11:10 架构）。
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let errorMessage {
                    errorState(errorMessage)
                } else if isLoading {
                    loadingState
                } else {
                    dailySection
                    recommendedSection
                    newAlbumsSection
                    toplistsSection
                    artistsSection
                }

                // 底栏留白：迷你播放器 + Tab 胶囊
                Color.clear.frame(height: 170)
            }
            .padding(.top, 8)
        }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    // MARK: - 加载

    private func load(force: Bool = false) async {
        if isLoading == false && !force { return }
        isLoading = true
        errorMessage = nil

        async let dailyTask = try? NeteaseMusicAPI.shared.dailyRecommendSongs()
        async let recsTask = try? NeteaseMusicAPI.shared.personalizedPlaylists(limit: 30)
        async let albumsTask = try? NeteaseMusicAPI.shared.newAlbums(limit: 20)
        async let topsTask = try? NeteaseMusicAPI.shared.toplists()
        async let artistsTask = try? NeteaseMusicAPI.shared.topArtists(limit: 30)

        let (daily, recs, albums, tops, arts) = await (dailyTask, recsTask, albumsTask, topsTask, artistsTask)
        dailySongs = daily ?? []
        recommendedPlaylists = recs ?? []
        newAlbums = albums ?? []
        toplists = tops ?? []
        artists = arts ?? []
        isLoading = false

        if dailySongs.isEmpty && recommendedPlaylists.isEmpty && newAlbums.isEmpty && toplists.isEmpty && artists.isEmpty {
            errorMessage = "内容加载失败，请下拉重试"
        }
    }

    // MARK: - 推荐歌单（个性化推荐货架）

    @ViewBuilder
    private var recommendedSection: some View {
        if !recommendedPlaylists.isEmpty {
            WellShelf(title: "推荐歌单") {
                ForEach(recommendedPlaylists) { pl in
                    NavigationLink {
                        WellPlaylistDetailView(
                            source: .playlist(id: pl.id, platform: .netease, name: pl.name),
                            coverURL: pl.coverURL,
                            creatorName: pl.creatorName,
                            playCount: pl.playCount)
                    } label: {
                        WellCoverCard(coverURL: pl.coverURL, title: pl.name,
                                      subtitle: pl.creatorName, playCount: pl.playCount)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 每日推荐（含私人漫游 / 心动模式入口）

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            WellSectionHeader(title: "推荐")
                .padding(.horizontal, WellSearchMetrics.contentInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    Color.clear.frame(width: WellSearchMetrics.contentInset - 14, height: 1)

                    // 每日推荐：点击打开**歌单页面**（WellPlaylistDetailView 歌单页样式，
                    // 数据走 dailyRecommendSongs），不是直接播放
                    NavigationLink {
                        WellPlaylistDetailView(
                            source: .playlist(id: "daily", platform: .netease, name: "每日推荐"),
                            coverURL: nil,
                            dailyMode: true)
                    } label: {
                        WellFeatureCard(
                            title: "每日推荐",
                            subtitle: dailySubtitle,
                            icon: "calendar",
                            coverURL: dailySongs.first?.albumCoverURL,
                            gradient: [Color(red: 0.95, green: 0.36, blue: 0.28),
                                       Color(red: 0.96, green: 0.68, blue: 0.30)]
                        )
                    }
                    .buttonStyle(.plain)

                    WellFeatureCard(
                        title: "私人漫游",
                        subtitle: "从喜欢的歌开始漫游",
                        icon: "wave.3.right.circle.fill",
                        coverURL: nil,
                        gradient: [Color(red: 0.16, green: 0.22, blue: 0.42),
                                   Color(red: 0.41, green: 0.28, blue: 0.65)]
                    ) {
                        Task { await startPersonalFM() }
                    }

                    WellFeatureCard(
                        title: "心动模式",
                        subtitle: "你的红心歌曲和相似推荐",
                        icon: "heart.circle.fill",
                        coverURL: nil,
                        gradient: [Color(red: 0.84, green: 0.16, blue: 0.38),
                                   Color(red: 0.98, green: 0.43, blue: 0.35)]
                    ) {
                        Task { await startHeartbeat() }
                    }

                    Color.clear.frame(width: WellSearchMetrics.contentInset - 14, height: 1)
                }
                .padding(.vertical, 4)
            }
            .modifier(WellHorizontalClipModifier())
        }
    }

    private var dailySubtitle: String {
        dailySongs.isEmpty ? "每天 6:00 更新" : "\(dailySongs.count) 首 · 每天 6:00 更新"
    }

    /// 私人漫游：连续批次灌入队列（Beans 同款行为 —— 先起播再持续 append）。
    private func startPersonalFM() async {
        guard actionLoading == nil else { return }
        actionLoading = "fm"
        defer { actionLoading = nil }

        var started = false
        do {
            let tracks = try await NeteaseMusicAPI.shared.personalFMTracks(batches: 2)
            guard !tracks.isEmpty else {
                ToastCenter.shared.show("私人漫游暂时没有推荐")
                return
            }
            started = true
            PlayerCore.shared.play(queue: tracks, startIndex: 0)
            ToastCenter.shared.show("已开启私人漫游")
        } catch {
            if !started { ToastCenter.shared.show("私人漫游加载失败") }
        }
    }

    /// 心动模式：以「我喜欢」歌单随机种子走 intelligenceList；失败逐级兜底
    /// （相似歌曲 simiSong → 我喜欢歌单随机起播），保证总能出歌。
    /// 网易云老规矩：「我喜欢的音乐」歌单 id == 用户 uid。
    private func startHeartbeat() async {
        guard actionLoading == nil else { return }
        actionLoading = "heartbeat"
        defer { actionLoading = nil }

        guard let uid = NeteaseSession.shared.account?.userId else {
            ToastCenter.shared.show("请先登录网易云")
            return
        }
        let likedId = "\(uid)"

        // 种子：我喜欢歌单随机一首
        var seedId: String?
        var likedTracks: [MusicItem] = []
        if let list = try? await NeteaseMusicAPI.shared.playlistTracks(id: likedId), !list.isEmpty {
            likedTracks = list
            seedId = list.randomElement()?.neteaseId
        }

        // ① 种子 + 口味范围 → intelligenceList（服务端推相似串）
        if let seedId {
            if let songs = try? await NeteaseMusicAPI.shared.intelligenceList(songId: seedId, playlistId: likedId),
               !songs.isEmpty {
                PlayerCore.shared.play(queue: songs, startIndex: 0)
                ToastCenter.shared.show("已开启心动模式")
                return
            }
            // ② 相似歌曲兜底
            if let songs = try? await NeteaseMusicAPI.shared.simiSongs(songId: seedId), !songs.isEmpty {
                PlayerCore.shared.play(queue: songs, startIndex: 0)
                ToastCenter.shared.show("已开启心动模式")
                return
            }
        }

        // ③ 最后兜底：我喜欢歌单随机起播（总能出歌）
        if !likedTracks.isEmpty {
            let shuffled = likedTracks.shuffled()
            PlayerCore.shared.play(queue: shuffled, startIndex: 0)
            ToastCenter.shared.show("已开启心动模式")
            return
        }

        ToastCenter.shared.show("先收藏一些喜欢的歌曲吧")
    }

    // MARK: - 新碟上架

    @ViewBuilder
    private var newAlbumsSection: some View {
        if !newAlbums.isEmpty {
            WellShelf(title: "新碟上架") {
                ForEach(newAlbums) { album in
                    NavigationLink {
                        WellPlaylistDetailView(
                            source: .album(id: album.id, platform: album.platform,
                                           name: album.name, artist: album.artistName),
                            coverURL: album.picURL,
                            creatorName: album.artistName)
                    } label: {
                        WellCoverCard(coverURL: album.picURL, title: album.name,
                                      subtitle: album.artistName)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 排行榜（横滑方卡，对齐 kumone HomeView 货架）

    @ViewBuilder
    private var toplistsSection: some View {
        if !toplists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                WellSectionHeader(title: "排行榜")
                    .padding(.horizontal, WellSearchMetrics.contentInset)

                // ⚠️ 项目铁律：横向货架用 HStack 绝不用 LazyHStack
                //（LazyHStack 交叉轴测不出高 → 卡片全叠 y=0）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        Color.clear.frame(width: WellSearchMetrics.contentInset - 14, height: 1)

                        ForEach(toplists.prefix(10)) { top in
                            NavigationLink {
                                WellPlaylistDetailView(
                                    source: .playlist(id: top.id, platform: .netease, name: top.name),
                                    coverURL: top.coverURL)
                            } label: {
                                WellToplistCard(item: top)
                            }
                            .buttonStyle(.plain)
                        }

                        Color.clear.frame(width: WellSearchMetrics.contentInset - 14, height: 1)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - 热门歌手

    @ViewBuilder
    private var artistsSection: some View {
        if !artists.isEmpty {
            WellShelf(title: "热门歌手") {
                ForEach(artists) { artist in
                    NavigationLink {
                        WellPlaylistDetailView(
                            source: .artist(id: artist.id, platform: artist.platform, name: artist.name),
                            coverURL: artist.picURL)
                    } label: {
                        WellArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 状态视图

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在加载推荐内容…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await load(force: true) }
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
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

// MARK: - 功能入口卡（每日推荐 / 私人漫游 / 心动模式）

/// 大号入口卡：有封面用封面 + 底部渐变，无封面用品牌渐变 + 图标水印。
/// `destination` 非空时整卡是 NavigationLink（如每日推荐进列表页），
/// 否则点按执行 `action`（如私人漫游/心动模式直接起播）。
struct WellFeatureCard: View {
    let title: String
    let subtitle: String
    let icon: String
    var coverURL: String?
    let gradient: [Color]
    var isLoading: Bool = false
    var action: () -> Void = {}

    private let width: CGFloat = 160
    private let height: CGFloat = 160

    var body: some View {
        Button(action: action) { cardBody }
            .buttonStyle(WellPressButtonStyle())
            .disabled(isLoading)
    }

    private var cardBody: some View {
            ZStack(alignment: .bottomLeading) {
                background

                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))

                    Spacer(minLength: 0)

                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
                .padding(14)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var background: some View {
        if let coverURL, !coverURL.isEmpty {
            WellRemoteImage(url: coverURL, displaySize: height)
                .frame(width: width, height: height)
                .overlay(
                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.62)],
                                   startPoint: .top, endPoint: .bottom)
                )
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 92, height: 92)
                        .blur(radius: 3)
                        .offset(x: 24, y: -26)
                }
                .overlay(alignment: .center) {
                    Image(systemName: icon)
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.28))
                        .offset(x: 34, y: -18)
                }
        }
    }
}

// MARK: - 榜单卡（kumone 式：方图 + 底部渐变 + 左下角更新频率 + 图下榜单名）

struct WellToplistCard: View {
    let item: WellToplistSummary

    private let size: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                WellRemoteImage(url: item.coverURL, displaySize: size)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(item.updateFrequency ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(8)
            }
            .frame(width: size, height: size)

            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 辅助

/// 横向货架不裁剪溢出（iOS 17+ 才有 `scrollClipDisabled`）。
private struct WellHorizontalClipModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}

/// 轻微按压缩放（替代 kumone 的 GlassPressButtonStyle）。
struct WellPressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

#Preview {
    DiscoverView()
}
