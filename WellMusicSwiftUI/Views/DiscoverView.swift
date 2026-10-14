import SwiftUI

/// 发现页（首页）—— 代码按本项目架构重写。
///
/// 板块（自上而下）：
/// 1. `dailySection`  每日推荐：横滑入口卡（每日推荐 / 私人漫游 / 心动模式），
///    两种样式按设置「发现页入口卡」切换（封面方卡 156pt / 经典横卡 264×88），
///    均无分区标题
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

    /// 登录网易云 → 关注歌手；未登录 → 热门歌手
    private func loadArtists() async -> [WellArtistSummary] {
        if NeteaseSession.shared.isLoggedIn {
            return (try? await NeteaseMusicAPI.shared.followedArtists(limit: 30)) ?? []
        }
        return (try? await NeteaseMusicAPI.shared.topArtists(limit: 30)) ?? []
    }

    private func load(force: Bool = false) async {
        if isLoading == false && !force { return }
        isLoading = true
        errorMessage = nil

        async let dailyTask = try? NeteaseMusicAPI.shared.dailyRecommendSongs()
        async let recsTask = try? NeteaseMusicAPI.shared.personalizedPlaylists(limit: 30)
        async let albumsTask = try? NeteaseMusicAPI.shared.newAlbums(limit: 20)
        async let topsTask = try? NeteaseMusicAPI.shared.toplists()
        async let artistsTask = loadArtists()

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
            WellShelf(title: "推荐歌单", rowHeight: 220) {
                ForEach(Array(recommendedPlaylists.enumerated()), id: \.element.id) { index, pl in
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
                    .modifier(WellCardEntrance(index: index, itemID: "rec-\(pl.id)"))
                }
            }
        }
    }

    // MARK: - 每日推荐（含私人漫游 / 心动模式入口）

    /// 两种卡片样式按设置切换（用户 2026-10-14：两种都保留、设置里可换）：
    /// - `.cover`：与「推荐歌单」货架同尺寸的 156pt 方图卡（`WellFeatureCard`）
    /// - `.action`：经典 264×88 横卡（`WellActionCard`）
    ///
    /// 两种样式都**不渲染分区标题**（「推荐」标题按用户要求去除）。
    @AppStorage("wellmusic.discover.dailyCardStyle") private var dailyCardStyle: WellDailyCardStyle = .cover

    @ViewBuilder
    private var dailySection: some View {
        if dailyCardStyle == .cover {
            dailyCoverSection
        } else {
            dailyActionSection
        }
    }

    /// 封面方卡样式：`WellShelf` 统一边缘内衬与懒加载，行高与推荐歌单一致（220）。
    private var dailyCoverSection: some View {
        // ⚠️ 参数必须按 WellShelf 的声明顺序：title → rowHeight → showsHeader
        //    （memberwise init 对顺序敏感，错序会报 "argument ... must precede ..."）。
        WellShelf(title: "推荐", rowHeight: 220, showsHeader: false) {
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
                    icon: "calendar",
                    coverURL: dailySongs.first?.albumCoverURL,
                    gradient: [Color(red: 0.95, green: 0.36, blue: 0.28),
                               Color(red: 0.96, green: 0.68, blue: 0.30)])
            }
            .buttonStyle(.plain)
            .modifier(WellCardEntrance(index: 0, itemID: "daily-rec"))

            Button {
                Task { await startPersonalFM() }
            } label: {
                WellFeatureCard(
                    title: "私人漫游",
                    subtitle: "从喜欢的歌开始漫游",
                    icon: "wave.3.right.circle.fill",
                    gradient: [Color(red: 0.16, green: 0.22, blue: 0.42),
                               Color(red: 0.41, green: 0.28, blue: 0.65)])
            }
            .buttonStyle(.plain)
            .modifier(WellCardEntrance(index: 1, itemID: "daily-fm"))

            Button {
                Task { await startHeartbeat() }
            } label: {
                WellFeatureCard(
                    title: "心动模式",
                    subtitle: "你的红心歌曲和相似推荐",
                    icon: "heart.circle.fill",
                    gradient: [Color(red: 0.84, green: 0.16, blue: 0.38),
                               Color(red: 0.98, green: 0.43, blue: 0.35)])
            }
            .buttonStyle(.plain)
            .modifier(WellCardEntrance(index: 2, itemID: "daily-heartbeat"))
        }
    }

    /// 经典横卡样式：264×88 入口卡（`WellActionCard`），同样不带「推荐」标题。
    private var dailyActionSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                Color.clear.frame(width: WellSearchMetrics.contentInset - 14, height: 1)

                // 每日推荐：点击打开**歌单页面**（WellPlaylistDetailView 歌单页样式，
                // 数据走 dailyRecommendSongs），不是直接播放
                NavigationLink {
                    WellPlaylistDetailView(
                        source: .playlist(id: "daily", platform: .netease, name: "每日推荐"),
                        coverURL: nil,
                        dailyMode: true)
                } label: {
                    WellActionCard(
                        title: "每日推荐",
                        icon: "calendar",
                        coverURL: dailySongs.first?.albumCoverURL,
                        gradient: [Color(red: 0.95, green: 0.36, blue: 0.28),
                                   Color(red: 0.96, green: 0.68, blue: 0.30)])
                }
                .buttonStyle(.plain)

                Button {
                    Task { await startPersonalFM() }
                } label: {
                    WellActionCard(
                        title: "私人漫游",
                        subtitle: "从喜欢的歌开始漫游",
                        icon: "wave.3.right.circle.fill",
                        gradient: [Color(red: 0.16, green: 0.22, blue: 0.42),
                                   Color(red: 0.41, green: 0.28, blue: 0.65)])
                }
                .buttonStyle(.plain)

                Button {
                    Task { await startHeartbeat() }
                } label: {
                    WellActionCard(
                        title: "心动模式",
                        subtitle: "你的红心歌曲和相似推荐",
                        icon: "heart.circle.fill",
                        gradient: [Color(red: 0.84, green: 0.16, blue: 0.38),
                                   Color(red: 0.98, green: 0.43, blue: 0.35)])
                }
                .buttonStyle(.plain)

                Color.clear.frame(width: WellSearchMetrics.contentInset - 14, height: 1)
            }
            .frame(height: 112)
            .padding(.vertical, 4)
        }
    }

    /// 私人漫游：连续批次灌入队列（先起播，再持续 append 后续批次）。
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
    ///
    /// ★ 2026-10-14 用户反馈「登陆了网易云点击不能播放」→ 根因在**取种子这一步**：
    /// 之前用 `playlistTracks(id:)`（`n=100_000, s=8`），网易云对 `s=8` 只回 **10 条**、
    /// 且**忽略 `n`**；那 10 条里若没有可解析的 `neteaseId`，种子就取不到，
    /// 后面 intelligenceList / simiSongs 全部跳过，最终连「我喜欢随机起播」也因
    /// 列表为空而落到一句 toast —— 表现就是「点了没反应」。
    /// 现在改用与「我喜欢」页**同一个**已知可用的取列表接口 `playlistForImport`
    /// （走 `trackIds` 分块补齐，能拿到完整曲目），种子与兜底队列都稳了。
    private func startHeartbeat() async {
        guard actionLoading == nil else { return }
        actionLoading = "heartbeat"
        defer { actionLoading = nil }

        guard let uid = NeteaseSession.shared.account?.userId else {
            ToastCenter.shared.show("请先登录网易云")
            return
        }
        let likedId = "\(uid)"

        // 种子：我喜欢歌单随机一首（完整列表，见上方说明）
        var seedId: String?
        var likedTracks: [MusicItem] = []
        if let imported = try? await NeteaseMusicAPI.shared.playlistForImport(id: likedId),
           !imported.tracks.isEmpty {
            likedTracks = imported.tracks
            seedId = likedTracks.randomElement()?.neteaseId
        }
        // 兜底一次：极端情况下（大歌单 trackIds 缺失）退回老接口，至少拿到前 10 条
        if likedTracks.isEmpty,
           let list = try? await NeteaseMusicAPI.shared.playlistTracks(id: likedId), !list.isEmpty {
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
            PlayerCore.shared.play(queue: likedTracks.shuffled(), startIndex: 0)
            ToastCenter.shared.show("已开启心动模式")
            return
        }

        ToastCenter.shared.show("先收藏一些喜欢的歌曲吧")
    }

    // MARK: - 新碟上架

    @ViewBuilder
    private var newAlbumsSection: some View {
        if !newAlbums.isEmpty {
            WellShelf(title: "新碟上架", rowHeight: 220) {
                ForEach(Array(newAlbums.enumerated()), id: \.element.id) { index, album in
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
                    .modifier(WellCardEntrance(index: index, itemID: "album-\(album.id)"))
                }
            }
        }
    }

    // MARK: - 排行榜（横滑方卡）

    @ViewBuilder
    private var toplistsSection: some View {
        if !toplists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                WellSectionHeader(title: "排行榜")
                    .padding(.horizontal, WellSearchMetrics.contentInset)

                // ⚠️ 项目铁律：横向货架用 HStack 绝不用 LazyHStack
                //（LazyHStack 交叉轴测不出高 → 卡片全叠 y=0）
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        Color.clear.frame(width: WellSearchMetrics.contentInset - 14, height: 1)

                        ForEach(Array(toplists.prefix(10).enumerated()), id: \.element.id) { index, top in
                            NavigationLink {
                                WellPlaylistDetailView(
                                    source: .playlist(id: top.id, platform: .netease, name: top.name),
                                    coverURL: top.coverURL)
                            } label: {
                                WellToplistCard(item: top)
                            }
                            .buttonStyle(.plain)
                            .modifier(WellCardEntrance(index: index, itemID: "top-\(top.id)"))
                        }

                        Color.clear.frame(width: WellSearchMetrics.contentInset - 14, height: 1)
                    }
                    .frame(height: 200)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - 热门歌手

    @ViewBuilder
    private var artistsSection: some View {
        if !artists.isEmpty {
            // 登录网易云 → 关注歌手；未登录 → 热门歌手
            WellShelf(title: artistSectionTitle, rowHeight: 170) {
                ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                    NavigationLink {
                        WellArtistHomeView(artistId: artist.id, artistName: artist.name,
                                           coverURL: artist.picURL)
                    } label: {
                        WellArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                    .modifier(WellCardEntrance(index: index, itemID: "artist-\(artist.id)"))
                }
            }
        }
    }

    private var artistSectionTitle: String {
        NeteaseSession.shared.isLoggedIn ? "关注歌手" : "热门歌手"
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

/// 经典横长入口卡（264×88）：`[64pt 圆角图标块] 标题 / 副标题`，
/// 浅色底 + 细描边，与应用整体风格一致。
///
/// 与 `WellFeatureCard`（封面方卡）并存，按设置项「发现页入口卡」切换
/// （用户 2026-10-14：两种样式都保留）。
/// **纯视觉视图**（不含 Button）：点击行为由外层 NavigationLink / Button 提供，
/// 避免 label 内嵌 Button 吞掉 NavigationLink 的点击（踩过：每日推荐点不进去）。
struct WellActionCard: View {
    let title: String
    var subtitle: String?
    let icon: String
    var coverURL: String?
    let gradient: [Color]

    var body: some View {
        HStack(spacing: 14) {
            iconBlock

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 264, height: 88)
        .background(AppTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 左侧 64pt 图标块：有封面用封面图，无封面用渐变 + 居中白图标
    /// （图标同样放大 + 降低不透明度，与方卡样式保持一致，见 `WellFeatureCard.artwork`）。
    @ViewBuilder
    private var iconBlock: some View {
        let base = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if let coverURL, !coverURL.isEmpty {
            WellRemoteImage(url: coverURL, displaySize: 64)
                .frame(width: 64, height: 64)
                .clipShape(base)
        } else {
            base
                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
        }
    }
}

/// 方图入口卡，与「推荐歌单」货架的 `WellCoverCard` **同尺寸**
/// （`WellSearchMetrics.cardSize` = 156pt 方图 + 图下标题/副标题）——
/// 用户 2026-10-14 明确要求这三张卡和推荐歌单一样的长度宽度。
///
/// 有封面用封面图（每日推荐取当日首曲封面），无封面用渐变底 + 居中
/// 白色 SF Symbol（Apple Music 同类入口的观感）。
/// **纯视觉视图**（不含 Button）：点击行为由外层 NavigationLink / Button 提供，
/// 避免 label 内嵌 Button 吞掉 NavigationLink 的点击（踩过：每日推荐点不进去）。
struct WellFeatureCard: View {
    let title: String
    var subtitle: String?
    let icon: String
    var coverURL: String?
    let gradient: [Color]

    private let size: CGFloat = WellSearchMetrics.cardSize

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            artwork
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size)
        .contentShape(Rectangle())
    }

    /// 156pt 方图：有封面用封面图，无封面用渐变 + 居中白图标。
    ///
    /// ★ 2026-10-14 用户：「卡片中间的图标放大一点透明点」——
    /// 图标 44 → **58pt**、白色不透明度 1 → **0.45**（做成淡淡的底纹感，
    /// 不再是一块抢眼的实心白）。
    @ViewBuilder
    private var artwork: some View {
        let base = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if let coverURL, !coverURL.isEmpty {
            WellRemoteImage(url: coverURL, displaySize: size)
                .frame(width: size, height: size)
                .clipShape(base)
        } else {
            base
                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 58, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
        }
    }
}

// MARK: - 榜单卡（方图 + 底部渐变 + 左下角更新频率 + 图下榜单名）

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

/// 轻微按压缩放。
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
