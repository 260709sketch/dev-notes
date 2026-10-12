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
            case .personalFM: return "无限私人电台"
            case .intelligence: return "猜你爱听"
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

// MARK: - 发现页

/// 发现 Tab：推荐歌单 / 排行榜 / 新碟上架 / 热门歌手。
///
/// 版式与 kumone 的推荐页保持一致（横向货架 + 同尺寸卡片），
/// 但全部由本项目自己的组件（`WellShelf` / `WellCoverCard` / `WellArtistCard`）搭建。
///
/// ⚠️ 本视图**不带 `NavigationStack`**：导航容器由 `MainTabView` 统一提供。
/// 原因见 `MainTabView.page(_:_:)` —— 四个 Tab 的导航栈同时在视图树中时，
/// 切换可见性会让四个导航栏一起重新测量，大标题与整页都会跳一下。
///
/// `@MainActor`：功能卡片的加载在 `Task` 里跑，标上主 actor 让
/// `Task` 继承主线程上下文，才能直接改 `@MainActor` 的 ViewModel 状态。
@MainActor
struct DiscoverView: View {
    @EnvironmentObject private var player: PlayerCore
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
                    featureRow
                    loadedBody
                }

                // 底栏（迷你播放器 + Tab 胶囊）留白：约 54 + 8 + 64 + 安全区
                Color.clear.frame(height: 150)
            }
            .padding(.top, 6)
        }
        // ignoresSafeArea：否则屏幕最上/最下的安全区会露出下层底色。
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("发现")
        .task { await model.loadIfNeeded() }
        .refreshable { await model.reload() }
    }

    // MARK: 功能卡片

    /// 顶部横滑功能卡：每日推荐 / 私人漫游 / 心动模式。
    private var featureRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Color.clear.frame(width: contentInset - 12, height: 1)
                ForEach(WellDiscoverViewModel.Feature.allCases) { feature in
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
                Color.clear.frame(width: contentInset - 12, height: 1)
            }
            .padding(.vertical, 2)
        }
    }

    private func cover(for feature: WellDiscoverViewModel.Feature) -> String? {
        switch feature {
        case .daily:
            return model.dailyCoverURL
        case .personalFM:
            // 私人漫游没有专属封面，用榜单里第一张图当视觉锚点（对齐 RN 版做法）
            return model.toplists.first?.coverURL
        case .intelligence:
            return model.toplists.dropFirst().first?.coverURL
        }
    }

    private func subtitle(for feature: WellDiscoverViewModel.Feature) -> String {
        switch feature {
        case .daily:
            return model.dailySongs.isEmpty ? feature.tagline : "\(model.dailySongs.count) 首 · \(feature.tagline)"
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

// MARK: - 功能卡片

/// 发现页顶部的功能卡（每日推荐 / 私人漫游 / 心动模式）。
///
/// 版式对齐 RN 版发现页的「功能卡片横滑」：正方形封面 + 底部渐变 + 图标角标，
/// 标题和副标题压在封面下方。加载中时封面变暗并叠一个菊花。
private struct WellFeatureCard: View {
    let feature: WellDiscoverViewModel.Feature
    let coverURL: String?
    let subtitle: String
    var busy: Bool = false

    private let size: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                WellRemoteImage(url: coverURL, displaySize: size)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // 底部渐变：保证角标和图标在浅色封面上也读得清
                LinearGradient(
                    colors: [.black.opacity(0.45), .clear, .black.opacity(0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack {
                    HStack {
                        Image(systemName: feature.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.32), in: Circle())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(9)

                if busy {
                    ZStack {
                        Color.black.opacity(0.35)
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .frame(width: size, height: size)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
    }
}
