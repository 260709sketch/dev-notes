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

    /// 每日推荐歌曲。除了给功能卡片当封面，也是「心动模式」的种子来源。
    @Published private(set) var dailySongs: [MusicItem] = []

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
        // 五路并发：各自失败只影响自己那一块，不拖垮整页
        async let playlistsTask = try? api.personalizedPlaylists(limit: 30)
        async let toplistsTask = try? api.toplists()
        async let albumsTask = try? api.newAlbums(limit: 20)
        async let artistsTask = try? api.topArtists(limit: 30)
        async let dailyTask = try? api.dailyRecommendSongs()

        let fetchedPlaylists = await playlistsTask ?? []
        let fetchedToplists = await toplistsTask ?? []
        let fetchedAlbums = await albumsTask ?? []
        let fetchedArtists = await artistsTask ?? []
        let fetchedDaily = await dailyTask ?? []

        playlists = fetchedPlaylists
        toplists = Array(fetchedToplists.prefix(12))
        albums = Array(fetchedAlbums.prefix(20))
        // 热门歌手取前 30 后再打散截取，避免每次都看到同一批面孔
        artists = Array(fetchedArtists.shuffled().prefix(12))
        dailySongs = fetchedDaily

        let nothingAtAll = playlists.isEmpty && toplists.isEmpty
            && albums.isEmpty && artists.isEmpty && dailySongs.isEmpty
        if nothingAtAll {
            // 全空时再补一次诊断请求，把真实报错捞出来 ——
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

    // MARK: 功能卡片（每日推荐 / 私人漫游 / 心动模式）

    /// 发现页顶部的三张功能卡。
    enum Feature: String, CaseIterable, Identifiable {
        case daily = "每日推荐"
        case personalFM = "私人漫游"
        case intelligence = "心动模式"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .daily: return "calendar"
            case .personalFM: return "dot.radiowaves.left.and.right"
            case .intelligence: return "heart.fill"
            }
        }

        var tagline: String {
            switch self {
            case .daily: return "每天 6:00 更新"
            case .personalFM: return "猜你喜欢的电台"
            case .intelligence: return "顺着这首往下听"
            }
        }

        /// 卡片底色。
        ///
        /// 「私人漫游」「心动模式」在服务端**没有对应的封面图** ——
        /// 之前拿榜单封面去凑，结果卡片上顶着「飙升榜」「新歌榜」的字样，
        /// 看起来就像两张榜单卡（用户一眼就看出不对）。
        /// 这两个功能本身也没有「封面」这个语义，所以改用设计好的品牌渐变，
        /// 靠图标 + 配色区分，比借一张不相干的图干净得多。
        var gradient: LinearGradient {
            switch self {
            case .daily:
                return LinearGradient(colors: [Color(red: 0.93, green: 0.35, blue: 0.24),
                                               Color(red: 0.86, green: 0.20, blue: 0.33)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
            case .personalFM:
                return LinearGradient(colors: [Color(red: 0.24, green: 0.28, blue: 0.68),
                                               Color(red: 0.45, green: 0.32, blue: 0.82)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
            case .intelligence:
                return LinearGradient(colors: [Color(red: 0.72, green: 0.20, blue: 0.45),
                                               Color(red: 0.91, green: 0.42, blue: 0.42)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    /// 功能卡加载失败的原因（View 拿去弹 toast）。
    @Published private(set) var featureMessage: String?

    /// 准备某张功能卡要播的队列。返回 nil 表示失败，原因在 `featureMessage`。
    ///
    /// 这里只负责「拿数据」，播放交给 View —— ViewModel 不依赖播放器，
    /// 免得音乐库层反过来持有播放引擎。
    func prepareQueue(for feature: Feature) async -> [MusicItem]? {
        featureMessage = nil
        switch feature {
        case .daily:
            if dailySongs.isEmpty {
                dailySongs = (try? await NeteaseMusicAPI.shared.dailyRecommendSongs()) ?? []
            }
            guard !dailySongs.isEmpty else {
                featureMessage = "每日推荐暂时拿不到，请稍后重试"
                return nil
            }
            return dailySongs

        case .personalFM:
            let tracks = (try? await NeteaseMusicAPI.shared.personalFMTracks(batches: 4)) ?? []
            guard !tracks.isEmpty else {
                featureMessage = "私人漫游暂时没有歌曲，请稍后重试"
                return nil
            }
            return tracks

        case .intelligence:
            if dailySongs.isEmpty {
                dailySongs = (try? await NeteaseMusicAPI.shared.dailyRecommendSongs()) ?? []
            }
            guard let seed = dailySongs.first?.neteaseId else {
                featureMessage = "心动模式需要一首种子歌曲，请先加载每日推荐"
                return nil
            }
            // 口味范围优先用「我喜欢的音乐」，但用户歌单列表还没接，
            // 这里按服务端约定退化成种子歌曲自身 id —— 与 RN 版的兜底一致。
            let tracks = (try? await NeteaseMusicAPI.shared.intelligenceList(
                songId: seed, playlistId: seed)) ?? []
            guard !tracks.isEmpty else {
                featureMessage = "心动模式暂时拿不到歌曲，请稍后重试"
                return nil
            }
            return tracks
        }
    }

    func clearFeatureMessage() { featureMessage = nil }

    /// 正在加载的功能卡（显示菊花，同时防重复点击）。
    @Published private(set) var busyFeature: Feature?

    func setBusy(_ feature: Feature?) { busyFeature = feature }

    /// 每日推荐卡片的封面：拿日推第一首的专辑图，比放一张固定图更有信息量。
    var dailyCoverURL: String? { dailySongs.first?.albumCoverURL }
}

/// 发现页的版式常量。
///
/// 抽出来的理由：卡片尺寸是这一页的「节奏来源」—— 四个货架交替大小，
/// 竖着滑下来才不会像一堵同样规格的墙。集中在这里便于整体调。
enum DiscoverLayout {
    /// 功能卡（横滑三张）。加大一档：私人漫游 / 心动模式的压图文字才放得下。
    static let featureSize: CGFloat = 176
    /// 推荐歌单
    static let cardLarge: CGFloat = 156
    /// 新碟上架（比推荐歌单小一档）
    static let cardMedium: CGFloat = 132
    /// 热门歌手
    static let artistSmall: CGFloat = 108
    /// 分区之间的竖向间距
    static let sectionSpacing: CGFloat = 30
}

// MARK: - 发现页

/// 发现 Tab。
///
/// ## 版面结构（从上到下）
/// 1. **功能卡横滑**：每日推荐 / 私人漫游 / 心动模式 —— 方形视觉 + 压图文字，
///    整张卡即播放按钮；
/// 2. **推荐歌单**（156）/ **排行榜**（156，更新频率压渐变）/ **新碟上架**（132）/
///    **热门歌手**（圆形 108）。
///
/// ## 设计上的三条线
/// - **节奏**：四个货架刻意交替大小尺寸，竖着滑下来不是一堵同规格的墙
///   （尺寸集中在 `DiscoverLayout`）；
/// - **编辑感**：分区标题带一句说明（「根据你的口味」），像音乐杂志的栏目导语；
/// - **一致的层级**：抬头、卡片圆角、渐变遮罩的用法与搜索页/详情页同一套语汇，
///   所以这里不另起炉灶做特殊样式。
///
/// ⚠️ 本视图**不带 `NavigationStack`**：导航容器由 `MainTabView` 统一提供。
/// 原因见 `MainTabView.page(_:_:)` —— 四个 Tab 的导航栈同时在视图树中时，
/// 切换可见性会让四个导航栏一起重新测量，大标题与整页都会跳一下。
///
/// `@MainActor`：功能卡片的加载在 `Task` 里跑，标上主 actor 让
/// `Task` 继承主线程上下文，才能直接改 `@MainActor` 的 ViewModel 状态。
@MainActor
struct DiscoverView: View {
    /// ⚠️ 刻意**不用** `@EnvironmentObject`：`PlayerCore` 每 0.05s 推一次 `currentTime`，
    /// 只要订阅了它，本页 `body` 就跟着每秒重算 20 次 —— 页面里有几十张卡时滚动直接卡死。
    /// 本页只在点击时**发起播放**、不显示任何播放状态，所以直接取单例，不订阅。
    private var player: PlayerCore { PlayerCore.shared }
    @StateObject private var model = WellDiscoverViewModel()

    private var contentInset: CGFloat { WellSearchMetrics.contentInset }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DiscoverLayout.sectionSpacing) {
                switch model.phase {
                case .loading:
                    skeletonBody
                case .failed(let message):
                    failureBody(message)
                case .loaded:
                    featureRow
                    loadedBody
                }

                // 底栏（迷你播放器 + Tab 胶囊）留白：约 54 + 8 + 64 + 安全区
                Color.clear.frame(height: 150)
            }
            .padding(.top, 6)
        }
        // ★ 沉浸式底部（与 kumone 一致，用户 2026-10-13 指令）：
        //   内容延伸到底部安全区域，液态玻璃 TabBar 浮在内容上透出模糊倒影。
        //   底部 150pt 留白确保最后一条内容不被 TabBar 永久遮挡。
        .ignoresSafeArea(edges: .bottom)
        // ★ 不铺背景、不给 toolbar 上色（与 kumone HomeView 一致）——
        //   全部交给系统 Liquid Glass 渲染链自动融合，颜色才连续。
        //   之前手动铺 background + toolbarBackground 与系统底色打架 → 顶部/底部白边。
        .navigationTitle("主页")
        .task { await model.loadIfNeeded() }
        .refreshable { await model.reload() }
    }

    // MARK: 功能卡片

    /// 顶部横滑功能卡：每日推荐 / 私人漫游 / 心动模式。
    ///
    /// 「每日推荐」进入**歌单式列表页**（`DailyRecommendListView`），不直接播放；
    /// 私人漫游 / 心动模式保持整卡即播放。
    private var featureRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Color.clear.frame(width: contentInset - 12, height: 1)
                ForEach(WellDiscoverViewModel.Feature.allCases) { feature in
                    if feature == .daily {
                        NavigationLink {
                            DailyRecommendListView()
                        } label: {
                            WellFeatureCard(
                                feature: feature,
                                coverURL: cover(for: feature),
                                subtitle: subtitle(for: feature),
                                busy: model.busyFeature == feature
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            start(feature)
                        } label: {
                            WellFeatureCard(
                                feature: feature,
                                coverURL: cover(for: feature),
                                subtitle: subtitle(for: feature),
                                busy: model.busyFeature == feature
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Color.clear.frame(width: contentInset - 12, height: 1)
            }
            .padding(.vertical, 2)
        }
    }

    private func cover(for feature: WellDiscoverViewModel.Feature) -> String? {
        // 只有「每日推荐」有真实封面可用（日推第一首的专辑图）—— 它也是三张卡里
        // 唯一「有内容实体」的功能。另外两张走 `Feature.gradient`。
        switch feature {
        case .daily: return model.dailyCoverURL
        case .personalFM, .intelligence: return nil
        }
    }

    private func subtitle(for feature: WellDiscoverViewModel.Feature) -> String {
        switch feature {
        case .daily:
            return model.dailySongs.isEmpty
                ? feature.tagline
                : "\(model.dailySongs.count) 首 · \(feature.tagline)"
        default:
            return feature.tagline
        }
    }

    /// 取队列 → 交给播放器。拿不到就弹提示。
    private func start(_ feature: WellDiscoverViewModel.Feature) {
        guard model.busyFeature == nil else { return }
        Task {
            model.setBusy(feature)
            defer { model.setBusy(nil) }
            guard let tracks = await model.prepareQueue(for: feature) else {
                if let message = model.featureMessage { ToastCenter.shared.show(message) }
                return
            }
            model.clearFeatureMessage()
            player.play(queue: tracks, startIndex: 0)
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var loadedBody: some View {
        if !model.playlists.isEmpty {
            WellShelf(title: "推荐歌单", subtitle: nil, action: nil) {
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
                            playCount: playlist.playCount,
                            size: DiscoverLayout.cardLarge
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.toplists.isEmpty {
            WellShelf(title: "排行榜", subtitle: nil) {
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
            WellShelf(title: "新碟上架", subtitle: nil) {
                ForEach(model.albums) { album in
                    NavigationLink {
                        WellSearchDetailView(
                            source: .album(id: album.id, platform: .netease,
                                           name: album.name, artist: album.artistName),
                            coverURL: album.picURL
                        )
                    } label: {
                        // 比「推荐歌单」小一档：四个货架交替出现大小尺寸，
                        // 竖着滑下来才有节奏，不会像一堵同规格的墙。
                        WellCoverCard(
                            coverURL: album.picURL,
                            title: album.name,
                            subtitle: album.artistName,
                            size: DiscoverLayout.cardMedium
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        if !model.artists.isEmpty {
            WellShelf(title: "热门歌手", subtitle: nil) {
                ForEach(model.artists) { artist in
                    NavigationLink {
                        WellSearchDetailView(
                            source: .artist(id: artist.id, platform: .netease, name: artist.name),
                            coverURL: artist.picURL
                        )
                    } label: {
                        WellArtistCard(artist: artist, size: DiscoverLayout.artistSmall)
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
        let size = DiscoverLayout.cardLarge
        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                WellRemoteImage(url: toplist.coverURL, displaySize: size)
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
        VStack(alignment: .leading, spacing: DiscoverLayout.sectionSpacing) {
            // 顶部三张功能卡（与真实布局同尺寸，避免数据回来时高度跳一下）
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppTheme.secondaryBackground)
                        .frame(width: DiscoverLayout.featureSize, height: DiscoverLayout.featureSize)
                }
            }
            .padding(.leading, contentInset)

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

// MARK: - 功能卡片

/// 发现页顶部的功能卡（每日推荐 / 私人漫游 / 心动模式）。
///
/// 版式取「编辑推荐位」的做法：**一张方形视觉 + 压在图上的标题/副标题**。
/// 视觉部分有真实封面就用封面（每日推荐→日推第一首的专辑图），
/// 没有就用该功能自己的品牌渐变 —— 见 `Feature.gradient` 里为什么不再借榜单封面。
///
/// 整张卡就是播放按钮：点一下直接开播，不做二次确认。
private struct WellFeatureCard: View {
    let feature: WellDiscoverViewModel.Feature
    let coverURL: String?
    let subtitle: String
    var busy: Bool = false

    /// 卡面尺寸。三张卡横滑，148 是「一屏刚好露出 2.2 张」的宽度 ——
    /// 露出的那截是横滑的天然提示，比任何箭头都直观。
    private let size: CGFloat = DiscoverLayout.featureSize

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            artwork

            // 压在图上的文字需要一层底衬，否则浅色封面上根本读不出来
            LinearGradient(colors: [.clear, .black.opacity(0.10), .black.opacity(0.62)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.rawValue)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            Image(systemName: feature.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.18), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                .padding(10)
        }
        .overlay {
            // 让卡片在浅色底上也有边界感
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .overlay {
            if busy { busyOverlay }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 卡面视觉：真实封面优先，否则品牌渐变。
    @ViewBuilder
    private var artwork: some View {
        if let coverURL, !coverURL.isEmpty {
            WellRemoteImage(url: coverURL, displaySize: size)
                // ⚠️ 不能写 `feature.gradient.opacity(0.28)`：
                // `ShapeStyle.opacity(_:)` 是 iOS 17 才有的 API，iOS 16 编不过。
                // 这里要的只是「压一层中性暗色让白字读得清」，用 Color 上的透明度等价。
                .overlay(Color.black.opacity(0.22))
        } else {
            feature.gradient
        }
    }

    private var busyOverlay: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.34))
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        }
    }
}
