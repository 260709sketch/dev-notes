import SwiftUI

/// 「我的歌单」排序方式（设置项：`wellmusic.profile.playlistSort`）。
enum WellPlaylistSort: String, CaseIterable, Identifiable {
    case manual = "默认"
    case name = "名称"
    case trackCount = "歌曲数"
    var id: String { rawValue }
}

/// 网易云账号歌单的「自定义位置」顺序（设置项：`wellmusic.profile.neteasePlaylistOrder`）。
///
/// 用户 2026-10-15：我的歌单「查看更多」页要能自己拖动排歌单位置。
/// 网易云歌单是每次进页面拉的服务端列表，本地没有存储顺序可依，
/// 所以把用户排好的**歌单 id 序列**存进 UserDefaults：
///   * `apply(to:)` 按已存顺序重排，API 返回里新出现的歌单（别处新建/收藏的）
///     按原序追加到末尾 —— 不打断用户已经排好的部分；
///   * 仅「默认」排序下生效（名称/歌曲数按组分别比较，与手动位置互斥）。
enum WellNeteasePlaylistOrder {
    private static let key = "wellmusic.profile.neteasePlaylistOrder"

    /// 自定义位置变化通知。「我的」页横滑货架把合并歌单缓存在 @State 里，
    /// 不会因为 UserDefaults 变化而刷新 —— 在「查看更多」页拖完歌单后，
    /// 靠它通知货架重算，两边顺序才一致。
    static let orderChangedNotification =
        Notification.Name("wellmusic.profile.neteasePlaylistOrder.changed")

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: key)
        NotificationCenter.default.post(name: Self.orderChangedNotification, object: nil)
    }

    /// 按已存顺序重排；未登记的新歌单按原顺序追加到末尾。
    static func apply(to items: [NeteaseMusicAPI.UserPlaylistItem]) -> [NeteaseMusicAPI.UserPlaylistItem] {
        let saved = load()
        guard !saved.isEmpty else { return items }
        var byID: [String: NeteaseMusicAPI.UserPlaylistItem] = [:]
        for item in items { byID[item.id] = item }
        var result: [NeteaseMusicAPI.UserPlaylistItem] = []
        var used = Set<String>()
        for id in saved {
            if let item = byID[id], !used.contains(id) {
                result.append(item)
                used.insert(id)
            }
        }
        for item in items where !used.contains(item.id) {
            result.append(item)
            used.insert(item.id)
        }
        return result
    }
}

/// 我的页横滑歌单的统一条目（本地歌单 + 网易云账号歌单合并后排）。
struct ProfilePlaylistItem: Identifiable {
    let id: String
    let name: String
    let coverURL: String?
    let subtitle: String
    let source: WellMyPlaylistSource
}

/// 我的 Tab —— 分组布局（用户 2026-10-15 定稿）。
///
/// 分组顺序（自上而下，用户 2026-10-16 定稿）：
///   ① 网易云账号卡（未登录 = 设置卡：蓝色设置钮 → 「设置 → 账号」登录；
///      已登录 = 头像 + 昵称 + VIP + 设置图标）
///   ② 「近期播放」经典横卡（软件内全部播放记录，纯本地含 MV，分段控制）
///   ③ 我的歌单：标题 + 查看更多，下方**横滑**选歌单（本地歌单 + 网易云账号）
///   ④ 最近喜欢：标题 + 查看更多，下方一列 **5 首**（本地收藏最新在前）
///   ⑤ 收藏专辑：一横两个（两列网格），排数随收藏数量
///   ⑥ 设置卡（原在最顶部，2026-10-16 按用户要求移到收藏专辑下面）
///
/// （原入口组的听歌排行/最近播放/我喜欢已按用户要求删除 —— 发现页已有。）
///
/// 分组标题 = `⌄ 标题 (数量)` + 右侧「查看更多」（Apple Music 音乐库风格）。
struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var session = NeteaseSession.shared
    @State private var showingSettings = false
    /// 点头像 → 底部弹出账号设置（未登录 = 登录入口；已登录 = 账号详情/退出登录）
    @State private var showingAccount = false

    /// 网易云账号歌单（第二分组横滑后半段；未登录保持空）
    @State private var neteasePlaylists: [NeteaseMusicAPI.UserPlaylistItem] = []
    /// 网易云收藏专辑（第四分组网格）
    @State private var favoriteAlbums: [WellAlbumSummary] = []
    /// 首屏异步数据（账号歌单 / 收藏专辑）是否仍在加载
    @State private var isLoadingContent = true
    /// 歌单排序方式（与「我的歌单」页共用同一设置项）
    @AppStorage("wellmusic.profile.playlistSort") private var playlistSortRaw: String = WellPlaylistSort.manual.rawValue

    private var playlistSort: WellPlaylistSort {
        WellPlaylistSort(rawValue: playlistSortRaw) ?? .manual
    }

    /// 合并后的歌单条目缓存（本地 + 网易云，按排序方式输出）。
    /// ⚠️ 原为计算属性：body 每次求值都要重建数组 + 排序（滚动/订阅刷新时反复执行）。
    /// 改为 @State 缓存，数据源或排序变化时由 `rebuildMergedPlaylists()` 更新。
    @State private var mergedPlaylists: [ProfilePlaylistItem] = []
    /// ★ 2026-10-16 问题8：最近喜欢的正在播放标识（低频订阅）
    @ObservedObject private var nowPlaying = NowPlayingTracker.shared

    /// 重算合并歌单（loadContent / 歌单变化 / 排序变化时调用）。
    private func rebuildMergedPlaylists() {
        mergedPlaylists = Self.buildMergedPlaylists(
            local: appState.playlists,
            netease: neteasePlaylists,
            sort: playlistSort)
    }

    private static func buildMergedPlaylists(
        local: [Playlist],
        netease: [NeteaseMusicAPI.UserPlaylistItem],
        sort: WellPlaylistSort
    ) -> [ProfilePlaylistItem] {
        // ★ 2026-10-16 用户（问题10b）：「调整了网易云歌单换本地歌单为什么顺序不一致，
        //   我想把网易云的歌单顺序固定到前面，本地自建的也可以调整到前面来」。
        //   根因：本货架原先「本地在前、网易云在后」，而「我的歌单」页
        //   （MyPlaylistsView）是「网易云 Section 在上、本地在下」——同一批
        //   歌单两处相对顺序相反；且名称/歌曲数排序把两组混排，两处口径仍对不上。
        //   修法：与页面两个 Section 的相对顺序保持一致 —— **网易云组在前、
        //   本地组在后**；排序方式按组分别应用后再拼接（不整组混排）。
        //   manual 下两组各自可拖：网易云 = WellNeteasePlaylistOrder 持久化顺序，
        //   本地 = appState.playlists 存储序（货架与页面共用同一底层，拖动任一处
        //   另一处跟着变）。
        func localItems(_ list: [Playlist]) -> [ProfilePlaylistItem] {
            list.map { pl in
                // ★ 2026-10-16 用户问题19：导入的 QQ 歌单在我的页也要显示平台标识
                //   （与详情页 platformDisplayName 同口径：sourcePlatform 优先，
                //   旧数据按曲目来源兜底推断）
                let platformSuffix: String
                if let sp = pl.sourcePlatform, !sp.isEmpty {
                    platformSuffix = sp == "qq" ? "QQ音乐" : "网易云"
                } else {
                    let sources = Set(pl.tracks.map(\.source))
                    if sources.count == 1, let only = sources.first {
                        switch only {
                        case .qq: platformSuffix = "QQ音乐"
                        case .netease: platformSuffix = "网易云"
                        default: platformSuffix = ""
                        }
                    } else {
                        platformSuffix = ""
                    }
                }
                let base = "\(pl.tracks.count) 首"
                return ProfilePlaylistItem(
                    id: "local_\(pl.id.uuidString)", name: pl.name, coverURL: pl.coverURL,
                    subtitle: platformSuffix.isEmpty ? base : "\(base) · \(platformSuffix)",
                    source: .local(pl))
            }
        }
        func neteaseItems(_ list: [NeteaseMusicAPI.UserPlaylistItem]) -> [ProfilePlaylistItem] {
            list.map { pl in
                ProfilePlaylistItem(
                    id: "ne_\(pl.id)", name: pl.name, coverURL: pl.coverURL,
                    subtitle: "\(pl.trackCount) 首 · 网易云",
                    source: .netease(id: pl.id, name: pl.name, coverURL: pl.coverURL, creatorName: "网易云音乐"))
            }
        }
        switch sort {
        case .manual:
            return neteaseItems(WellNeteasePlaylistOrder.apply(to: netease)) + localItems(local)
        case .name:
            let ne = netease.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let lo = local.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return neteaseItems(ne) + localItems(lo)
        case .trackCount:
            let ne = netease.sorted { $0.trackCount > $1.trackCount }
            let lo = local.sorted { $0.tracks.count > $1.tracks.count }
            return neteaseItems(ne) + localItems(lo)
        }
    }

    /// ⚠️ 性能铁律：不订阅 PlayerCore（20Hz 广播），只在点击时取单例发起播放。
    private var player: PlayerCore { PlayerCore.shared }

    /// 最近喜欢 = 本地收藏的最新 5 首（`favoriteTracks` 头插，最新在前）
    private var recentLikes: [MusicItem] { Array(appState.favoriteTracks.prefix(5)) }

    /// 「我的歌单」总数 = 本地歌单 + 网易云账号
    private var playlistTotalCount: Int { appState.playlists.count + neteasePlaylists.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                // ★ 2026-10-15 用户：「我的页上下滑动掉帧」——
                //   原为普通 VStack：**所有分组一次性全部构建**（收藏专辑几十张卡全量
                //   参与布局），滚动时每帧都要走过整棵子树。改 LazyVStack 后按需构建。
                // ★ 2026-10-16 用户：设置卡移到「收藏专辑」下面；页面整体上移
                //   （顶部留白 4→0、分组间距 26→22）；头像卡与近期播放卡间隙
                //   单独收窄到 10（两张卡包在同一个 VStack 里，不吃分组间距）。
                LazyVStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 10) {
                        // ★ 2026-10-15 用户：网易云登录卡片（置于「近期播放」上方）
                        accountCardSection
                        // ★ 2026-10-15 用户：「近期播放」经典横卡（置于「我的歌单」上方）
                        recentPlaysCard
                    }
                    playlistsSection
                    recentLikesSection
                    favoriteAlbumsSection
                    // ★ 2026-10-16 用户：设置卡移到收藏专辑分组下面
                    quickEntries

                    // 底栏（迷你播放器 52 + 间距 8 + 胶囊栏 64 + 距底 42 = 166）留白
                    Color.clear.frame(height: 170)
                }
                .padding(.top, 0)
            }
            .background(AppTheme.background)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await loadContent()
                rebuildMergedPlaylists()
            }
            // ★ 2026-10-15 用户：登录/退出网易云后，收藏专辑与账号歌单要跟着刷新
            //   （原先只在进页 task 拉一次，登录后回来还是空 = 「不同步」的观感来源）。
            // ★ 2026-10-16：这类「必须立刻同步」的场景要绕过刷新闸门（force），
            //   否则刚登录就被 5 分钟冷却挡住，观感还是「登录了没同步」。
            .onChange(of: session.isLoggedIn) { _ in
                Task { await loadContent(force: true) }
            }
            // ★ 2026-10-16 用户问题14：收藏专辑要自动同步网易云 —— 回到前台就强制
            //   拉一次（绕过刷新闸门），新收藏的专辑自动出现在分区里
            .onChange(of: scenePhase) { phase in
                if phase == .active, session.isLoggedIn {
                    Task { await loadContent(force: true) }
                }
            }
            // 合并歌单缓存的重算时机（本地歌单变化 / 排序变化；性能优化配套）
            .onChange(of: appState.playlists) { _ in
                rebuildMergedPlaylists()
            }
            .onChange(of: playlistSortRaw) { _ in
                rebuildMergedPlaylists()
            }
            // 网易云歌单在「查看更多」页被拖动重排后，横滑货架跟着重算
            .onReceive(NotificationCenter.default.publisher(
                for: WellNeteasePlaylistOrder.orderChangedNotification)) { _ in
                rebuildMergedPlaylists()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            // ★ 2026-10-14 用户：点头像要从底部弹出账号设置
            //   （原先已登录时是空实现，点了没反应）。
            //   NeteaseAccountSettingsView 未登录态自带「登录网易云音乐」入口
            //   （内部再弹 NeteaseLoginSheet），所以未登录点头像也能从这里登录。
            .sheet(isPresented: $showingAccount) {
                NavigationStack {
                    NeteaseAccountSettingsView()
                }
            }
        }
    }

    // MARK: - 分组标题（小标题 + 蓝色「查看更多」）

    /// 带「查看更多」的标题（跳转用 `NavigationLink`）。
    /// ⚠️ 2026-10-15 用户：去掉倒三角、字号调小（原 20pt bold → 17pt semibold）、
    /// 「查看更多」换成蓝色（原主题红）。
    private func groupHeader<Destination: View>(
        _ title: String,
        count: Int? = nil,
        @ViewBuilder seeAll: () -> Destination
    ) -> some View {
        HStack(spacing: 6) {
            Text(count.map { "\(title) (\($0))" } ?? title)
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 8)
            NavigationLink {
                seeAll()
            } label: {
                Text("查看更多")
                    .font(.system(size: 15))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    /// 无「查看更多」的标题（收藏专辑：全量展示，不另设入口）。
    private func plainGroupHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(count.map { "\(title) (\($0))" } ?? title)
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 分组① 设置（入口组已按用户要求删除）

    /// ★ 2026-10-15 用户：「我的歌单」上方的入口组（听歌排行 / 最近播放 /
    /// 我喜欢的音乐）**整组删除** —— 这些入口发现页都有了，不重复放。
    /// 设置不在发现页，保留为单独一张卡片。
    /// ★ 2026-10-16 用户：这张卡移到「收藏专辑」分组下面（页面最底部）。
    private var quickEntries: some View {
        VStack(spacing: 0) {
            // ★ 2026-10-15 用户：设置卡片融合到「听歌排行」分组里（原独立卡片）
            settingsEntryRow
        }
        .background(AppTheme.secondaryBackground,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    /// 设置行（与上方入口行同款，只是动作是弹设置 sheet）。
    private var settingsEntryRow: some View {
        Button {
            showingSettings = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(.blue)
                    .frame(width: 26)
                Text("设置").font(.system(size: 16)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 网易云登录卡片（用户 2026-10-15）

    /// 登录卡片（置于「近期播放」上方）：
    /// 未登录 = 登录入口；已登录 = 头像 + 昵称 + VIP 标识 + 右侧设置图标。
    private var accountCardSection: some View {
        NeteaseAccountCard()
            .padding(.horizontal, 16)
    }

    // MARK: - 近期播放（经典横卡；用户 2026-10-15）

    /// 「近期播放」入口卡：经典横卡样式（与发现页经典横卡同一视觉语言，
    /// 这里按「我的」页版式铺满宽）。点开 = `LocalRecentPlaysView`
    /// （软件内全部播放记录，纯本地，顶部分段控制切 歌曲/MV）。
    private var recentPlaysCard: some View {
        NavigationLink {
            LocalRecentPlaysView()
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.16, green: 0.22, blue: 0.42),
                                 Color(red: 0.41, green: 0.28, blue: 0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("近期播放")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(recentPlaysSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(AppTheme.secondaryBackground,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            // ★ 2026-10-16 用户（问题21）：阴影削减（7/0.10 → 4/0.06），
            //   去掉灰色描边（原先 Color.primary.opacity(0.06) 在浅色界面下
            //   就是一条灰线，用户明确「去除掉或者改成白色」—— 选择去除）
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    /// 横卡副标题：歌曲 / MV 各多少条。
    /// ★ 2026-10-16 用户（问题20）：数据纯本地，副标题加「本地」前缀明示。
    private var recentPlaysSubtitle: String {
        "本地 \(appState.playHistory.count) 首歌曲 · \(appState.mvHistory.count) 个 MV"
    }

    // MARK: - 分组② 我的歌单（标题 + 查看更多 + 横滑）

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            groupHeader("我的歌单", count: playlistTotalCount) { MyPlaylistsView() }

            if isLoadingContent && playlistTotalCount == 0 {
                loadingRow
            } else if playlistTotalCount == 0 {
                emptyRow("还没有歌单")
            } else {
                WellShelf(title: "", rowHeight: 192, showsHeader: false) {
                    ForEach(mergedPlaylists) { item in
                        NavigationLink {
                            WellMyPlaylistDetailView(source: item.source)
                        } label: {
                            playlistCard(name: item.name, coverURL: item.coverURL,
                                         subtitle: item.subtitle)
                        }
                        .buttonStyle(.plain)
                        // ★ 2026-10-15 用户：长按删除歌单（仅本地歌单；网易云账号歌单不可删）
                        .contextMenu {
                            if case .local(let pl) = item.source {
                                Button(role: .destructive) {
                                    appState.playlists.removeAll { $0.id == pl.id }
                                } label: {
                                    Label("删除歌单", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 横滑歌单卡（2026-10-15 用户：尺寸调小、副标题贴紧名称 —— 原先名称固定 2 行高，
    /// 一行名字时副标题被顶到 38pt 之外）。
    private static let playlistCardSide: CGFloat = 140

    private func playlistCard(name: String, coverURL: String?, subtitle: String) -> some View {
        let side = Self.playlistCardSide
        return VStack(alignment: .leading, spacing: 6) {
            WellRemoteImage(url: coverURL, displaySize: side)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background(AppTheme.secondaryBackground,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .frame(width: side, alignment: .leading)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: side, alignment: .leading)
        }
        .frame(width: side, alignment: .topLeading)
    }

    // MARK: - 分组③ 最近喜欢（标题 + 查看更多 + 5 首，支持左滑取消收藏）

    private var recentLikesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ★ 2026-10-15 用户：标题旁不显示歌曲数量
            groupHeader("最近喜欢") { LocalFavoriteSongsView() }

            if recentLikes.isEmpty {
                emptyRow("还没有喜欢的歌曲")
            } else {
                // ★ 2026-10-16 用户问题2「我的页上滑掉帧严重」：
                //   原实现用**内嵌 List**（为了 swipeActions）—— List 自带一套
                //   UICollectionView，嵌在 ScrollView 的 LazyVStack 里每屏都要
                //   参与布局协商，是本页掉帧的主嫌疑。换成轻量自绘左滑行
                //   （DragGesture + reveal 按钮），滚动路径上不再有嵌套集合视图。
                VStack(spacing: 0) {
                    ForEach(Array(recentLikes.enumerated()), id: \.offset) { index, track in
                        WellLikeSwipeRow {
                            likeRow(track, index: index)
                        } onDelete: {
                            appState.toggleFavorite(track)
                        }
                    }
                }
            }
        }
    }

    /// 歌曲行（46pt 封面 + 歌名 + 「歌手 · 平台」，点击播放）。
    /// ★ 2026-10-15 用户：标题字重与发现页歌单卡统一（medium）。
    /// ★ 2026-10-16 问题8：当前播放行显示音条动画。
    private func likeRow(_ track: MusicItem, index: Int) -> some View {
        Button {
            player.play(queue: appState.favoriteTracks, startIndex: index)
        } label: {
            HStack(spacing: 12) {
                WellRemoteImage(url: track.albumCoverURL, displaySize: 46)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .background(AppTheme.secondaryBackground,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(nowPlaying.isCurrent(track) ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(likeSubtitle(track))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if nowPlaying.isNowPlaying(track) {
                    NowPlayingIndicator()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func likeSubtitle(_ track: MusicItem) -> String {
        let platformName: String
        switch track.source {
        case .netease, .lx, .auto: platformName = "网易云"
        case .qq: platformName = "QQ音乐"
        case .kugou: platformName = "酷狗"
        case .kuwo: platformName = "酷我"
        }
        if let artist = track.artist, !artist.isEmpty {
            return "\(artist) · \(platformName)"
        }
        return platformName
    }

    // MARK: - 分组④ 收藏专辑（一横两个，全量展示）

    private var favoriteAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            plainGroupHeader("收藏专辑", count: favoriteAlbums.count)

            if isLoadingContent && favoriteAlbums.isEmpty {
                loadingRow
            } else if favoriteAlbums.isEmpty {
                if session.isLoggedIn {
                    // ★ 2026-10-15 用户：登录后拿不到收藏专辑 —— 空态给出**通道诊断**
                    //   与重试入口，便于定位（截图即可看到是哪条通道失败）。
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text("加载不到收藏专辑")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            Button("重试") {
                                // 用户主动重试：绕过冷却（否则点一下没反应）
                                Task { await loadContent(force: true) }
                            }
                            .font(.system(size: 14, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.accent)
                        }
                        if !NeteaseMusicAPI.lastFavoritedAlbumsDebug.isEmpty {
                            Text(NeteaseMusicAPI.lastFavoritedAlbumsDebug)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, WellSearchLayout.contentInset)
                } else {
                    emptyRow("登录后显示网易云收藏的专辑")
                }
            } else {
                // 复用搜索页的自适应两列网格与卡片
                WellCardGrid {
                    ForEach(favoriteAlbums) { album in
                        NavigationLink {
                            WellPlaylistDetailView(
                                source: .album(id: album.id, platform: album.platform,
                                               name: album.name, artist: album.artistName,
                                               mid: album.albumMid),
                                coverURL: album.picURL,
                                creatorName: album.artistName)
                        } label: {
                            WellCoverCard(coverURL: album.picURL,
                                          title: album.name,
                                          subtitle: album.artistName,
                                          fillWidth: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - 加载/空态行

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("加载中…").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    // MARK: - 数据加载

    private func loadContent(force: Bool = false) async {
        // ★ 2026-10-16 用户问题5/问题22：「打开专辑退出来后所有封面闪一下，好像是自动
        //   又刷新了」+「进入歌单后回到我的页不要再次触发刷新，频繁就限制刷新」。
        //    → 这里上「刷新闸门」：冷却期内直接返回，保留页面上已有的数据，
        //      不再打网络、不重建列表 —— 封面自然不会再集体闪一下。
        //   用户主动点「重试」、以及登录/退出这类必须立刻同步的场景走 force。
        let gateKey = "profile.content"
        if force { RefreshGate.shared.force(gateKey) }
        guard RefreshGate.shared.allow(gateKey) else { return }

        isLoadingContent = true
        if session.isLoggedIn {
            async let albumsTask = NeteaseMusicAPI.shared.favoritedAlbums(limit: 200)
            if let uid = session.account?.userId {
                async let playlistsTask = NeteaseMusicAPI.shared.userPlaylists(uid: uid)
                let fetched = (try? await playlistsTask) ?? []
                // 内容没变就不赋值：换一份等值的新数组同样会让货架整体重算
                if fetched != neteasePlaylists { neteasePlaylists = fetched }
            }
            let albums = (try? await albumsTask) ?? []
            if albums != favoriteAlbums { favoriteAlbums = albums }
        }
        rebuildMergedPlaylists()
        isLoadingContent = false
    }

    // MARK: 登录入口（原「我的」大标题右侧头像）

    // ⚠️ 2026-10-14 用户：「我的」右上角的头像 / 登录入口**暂时移除**
    //    （原挂载点是 body 上的 `.toolbar { ToolbarItem(placement: .topBarTrailing) { accountEntryButton } }`）。
    //    下面的实现**保留但暂不挂载**：恢复时把那段 toolbar 加回 body 即可。

    /// 未登录 = 人形图标（与 dock 栏「我的」同款 `person.crop.circle`）；
    /// 登录后 = 网易云头像。
    @ViewBuilder
    private var accountEntryButton: some View {
        Button {
            // ★ 2026-10-14 用户：点头像一律从底部弹出账号设置
            //   （未登录 = 登录入口；已登录 = 账号详情/退出登录）
            showingAccount = true
        } label: {
            if let account = session.account, session.isLoggedIn, let urlString = account.avatarURL, let url = URL(string: urlString), !urlString.isEmpty {
                WellAsyncImage(url: url) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 24))
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .task {
            // 进页面顺手校验一次票据：过期自动回到未登录态
            if session.isLoggedIn { await session.refreshAccount() }
        }
    }
}

// MARK: - 轻量左滑行（最近喜欢「取消收藏」用）

/// 自绘左滑行：DragGesture 横滑露出「取消收藏」，点按钮执行。
/// 只在横向位移明显大于纵向时才接管手势，不影响外层竖向滚动。
/// （2026-10-16 问题2：替代嵌套 List —— List 嵌在 ScrollView 的 LazyVStack 里
///   自带一套 UICollectionView，是本页掉帧主嫌疑。）
private struct WellLikeSwipeRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let onDelete: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var revealed = false

    private let revealWidth: CGFloat = 88

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    revealed = false
                    offsetX = 0
                }
                onDelete()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart.slash.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("取消收藏")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(width: revealWidth - 14)
                .frame(maxHeight: .infinity)
                .background(Color(red: 0.92, green: 0.28, blue: 0.32),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .opacity(offsetX < -6 ? 1 : 0)

            content()
                .background(AppTheme.background)
                .offset(x: offsetX)
                .gesture(drag)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let t = value.translation
                // 纵向位移更大 → 让给外层滚动
                guard abs(t.width) > abs(t.height) else { return }
                let base: CGFloat = revealed ? -revealWidth : 0
                offsetX = min(0, max(-revealWidth - 30, base + t.width))
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    revealed = offsetX < -revealWidth / 2
                    offsetX = revealed ? -revealWidth : 0
                }
            }
    }
}

/// 我的歌单：分两组 —— 网易云歌单（上）+ 本地歌单（下）。
///
/// 点进去一律走 `WellMyPlaylistDetailView`（用户 2026-10-14 截图 IMG_3957 版式）。
/// 本地歌单没有平台属性，所以详情页里不显示「网易云音乐」平台行；
/// 账号歌单则有 —— 这正是截图里的样子。
///
/// ★ 2026-10-15 用户：
///   ① 原「本地自建」分组改名「本地歌单」，并移到「网易云歌单」**下面**；
///   ② 右上角「编辑」进编辑态，可直接**拖动调整歌单位置** ——
///      本地歌单的位置就是 `appState.playlists` 的存储顺序；
///      网易云歌单的位置持久化在 `wellmusic.profile.neteasePlaylistOrder`
///      （服务端列表没有顺序可依，只能本地记 id 序列）。
///      拖动落在哪个排序视图上，就把那个视图的顺序固化成「默认」顺序
///      （见两处 `onMove`），避免 offsets 与底层数组错位。
struct MyPlaylistsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var session = NeteaseSession.shared

    /// 网易云账号歌单（未登录时保持为空，不请求）
    @State private var neteasePlaylists: [NeteaseMusicAPI.UserPlaylistItem] = []
    @State private var isLoadingNetease = false
    @State private var neteaseFailed = false

    var body: some View {
        List {
            // ★ 2026-10-15 用户：网易云歌单分组移到本地歌单上面
            if session.isLoggedIn {
                Section("网易云歌单") {
                    if isLoadingNetease && neteasePlaylists.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("加载中…").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if neteasePlaylists.isEmpty {
                        Text(neteaseFailed ? "暂时拿不到账号歌单" : "账号里还没有歌单")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedNeteasePlaylists) { pl in
                            NavigationLink {
                                WellMyPlaylistDetailView(
                                    source: .netease(id: pl.id, name: pl.name,
                                                     coverURL: pl.coverURL,
                                                     creatorName: "网易云音乐"))
                            } label: {
                                row(name: pl.name, coverURL: pl.coverURL,
                                    subtitle: "\(pl.trackCount) 首")
                            }
                        }
                        .onMove { offsets, destination in
                            // 拖动排序：把新顺序（歌单 id 序列）存进 UserDefaults。
                            // offsets 对应的是**当前展示数组**（可能是名称/歌曲数排序后的），
                            // 所以 move 之后还要切回「默认」排序，让展示与存下的顺序一致。
                            var ordered = sortedNeteasePlaylists
                            ordered.move(fromOffsets: offsets, toOffset: destination)
                            WellNeteasePlaylistOrder.save(ordered.map(\.id))
                            if sort != .manual { sortRaw = WellPlaylistSort.manual.rawValue }
                        }
                    }
                }
            }

            // ★ 2026-10-15 用户：原「本地自建」改名「本地歌单」，下移到网易云歌单分组下面
            Section("本地歌单") {
                if appState.playlists.isEmpty {
                    Text("还没有本地歌单")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedLocalPlaylists) { pl in
                        NavigationLink {
                            WellMyPlaylistDetailView(source: .local(pl))
                        } label: {
                            row(name: pl.name, coverURL: pl.coverURL,
                                subtitle: "\(pl.tracks.count) 首")
                        }
                    }
                    .onDelete { offsets in
                        // 排序后删除要把 offsets 映射回原数组下标
                        let sorted = sortedLocalPlaylists
                        let idsToDelete = offsets.map { sorted[$0].id }
                        appState.playlists.removeAll { idsToDelete.contains($0.id) }
                    }
                    .onMove { offsets, destination in
                        // 拖动排序：本地歌单的位置 = appState.playlists 的存储顺序。
                        // offsets 对应的是当前展示数组（可能是排序后的），move 之后
                        // 整个写回存储顺序；非「默认」排序下拖完顺手切回默认，
                        // 让用户看到的就是自己排的结果。
                        var list = sortedLocalPlaylists
                        list.move(fromOffsets: offsets, toOffset: destination)
                        appState.playlists = list
                        if sort != .manual { sortRaw = WellPlaylistSort.manual.rawValue }
                    }
                }
            }
        }
        .navigationTitle("我的歌单")
        .task { await loadNeteasePlaylists() }
        // ★ 2026-10-15 用户：右上角新增「歌单排序」（与我的页第二分组共用同一排序设置）。
        .toolbar {
            // ★ 2026-10-15 用户：右上角「编辑」进编辑态，支持拖动调整歌单位置
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("排序方式", selection: $sortRaw) {
                        ForEach(WellPlaylistSort.allCases) { sort in
                            Text(sort.rawValue).tag(sort.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        // ★ 2026-10-15 用户：原右上角「导入歌单 / 新建歌单」两个入口已合二为一，
        //   迁移到「设置 → 账号 → 导入歌单」（页内提供导入 + 新建），此处不再重复。
    }

    /// 排序方式（与「我的」页共用设置项 `wellmusic.profile.playlistSort`）。
    @AppStorage("wellmusic.profile.playlistSort") private var sortRaw: String = WellPlaylistSort.manual.rawValue

    private var sort: WellPlaylistSort { WellPlaylistSort(rawValue: sortRaw) ?? .manual }

    /// 本地歌单（按排序方式）。
    private var sortedLocalPlaylists: [Playlist] {
        switch sort {
        case .manual: return appState.playlists
        case .name:
            return appState.playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .trackCount:
            return appState.playlists.sorted { $0.tracks.count > $1.tracks.count }
        }
    }

    /// 网易云账号歌单（按排序方式）。
    private var sortedNeteasePlaylists: [NeteaseMusicAPI.UserPlaylistItem] {
        switch sort {
        // 默认排序 = 用户拖动出来的自定义位置（持久化的 id 序列）
        case .manual: return WellNeteasePlaylistOrder.apply(to: neteasePlaylists)
        case .name:
            return neteasePlaylists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .trackCount:
            return neteasePlaylists.sorted { $0.trackCount > $1.trackCount }
        }
    }

    private func row(name: String, coverURL: String?, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ArtworkView(url: coverURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 拉账号歌单（`api/user/playlist`）。未登录直接跳过，不浪费一次请求。
    private func loadNeteasePlaylists() async {
        guard session.isLoggedIn, let uid = session.account?.userId else { return }
        isLoadingNetease = true
        neteaseFailed = false
        do {
            neteasePlaylists = try await NeteaseMusicAPI.shared.userPlaylists(uid: uid)
        } catch {
            neteaseFailed = true
        }
        isLoadingNetease = false
    }
}

/// 歌单详情
///
/// ⚠️ 刻意**不用** `@EnvironmentObject`：`PlayerCore` 每 0.05s 推一次 `currentTime`，
/// 只要订阅了它，本页 `body` 就跟着每秒重算 20 次 —— 页面里有几十张卡时滚动直接卡死。
/// 本页只在点击时**发起播放**、不显示任何播放状态，所以直接取单例，不订阅。
struct PlaylistDetailView: View {
    private var player: PlayerCore { PlayerCore.shared }
    let playlist: Playlist

    var body: some View {
        List(playlist.tracks) { item in
            TrackRow(item: item)
                .onTapGesture {
                    player.play(queue: playlist.tracks, startIndex: playlist.tracks.firstIndex(of: item) ?? 0)
                }
        }
        .navigationTitle(playlist.name)
    }
}

// MARK: - 我喜欢（网易云「我喜欢的音乐」歌单）
//
// 网易云的老规矩：每个用户的「我喜欢的音乐」歌单 id == 用户 uid。
// ★ 2026-10-16 用户（新3）：「我的音乐我喜欢的音乐排序不是官方那种」——
// 官方顺序 = 该歌单在 `api/v6/playlist/detail` 里的 trackIds 顺序
// （官方 README「获取我喜欢的音乐」示例：userPlaylist → playlist[0].id →
// playlistDetail → trackIds；参考实现 v74/v77/v90 三版一致，不排序不反转）。
// `/api/song/like/get`（likelist）官方标注「喜欢的歌曲(无序)」，其 ids 顺序
// **不是**列表展示顺序 —— 原先把它当主通道正是排序不一致的根因，
// 现降级为兜底（歌单详情失败时至少能列出全部红心）。

struct NeteaseLikedSongsView: View {
    @State private var name = "我喜欢"
    @State private var coverURL: String?
    @State private var tracks: [MusicItem] = []
    @State private var isLoading = true
    @State private var notLoggedIn = false
    @State private var failed = false
    /// 创建者（= 用户自己）昵称 / 头像（问题2：标题下显示头像 + 名字）
    @State private var creatorName: String?
    @State private var creatorAvatarURL: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if notLoggedIn {
                tipView("还没有登录网易云", "登录后这里显示你红心收藏的所有歌曲")
            } else if failed {
                tipView("暂时拿不到", "网络开小差了，退出页面再进试试")
            } else if tracks.isEmpty {
                tipView("还没有喜欢的音乐", "在网易云里给歌曲点红心后会出现在这里")
            } else {
                // 复用「我的歌单」截图版式（小封面 + 红「播放全部」+ 歌曲列表）。
                // 标题由 WellMyPlaylistDetailView 统一留空（歌单页样式不含导航栏标题）。
                // ★ 2026-10-16 问题2：平台行给真实创建者（用户自己）的头像 + 昵称；
                //   问题10：播放全部上方一行简介。
                WellMyPlaylistDetailView(
                    source: .tracks(name: name, coverURL: coverURL,
                                    creatorName: creatorName ?? "网易云音乐", tracks: tracks),
                    introText: "来自你的网易云音乐",
                    creatorAvatarURL: creatorAvatarURL)
            }
        }
        .navigationTitle(isLoading || notLoggedIn || failed || tracks.isEmpty ? "我喜欢" : "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func tipView(_ title: String, _ note: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(note).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let uid = NeteaseSession.shared.account?.userId else {
            notLoggedIn = true
            isLoading = false
            return
        }
        // 主通道：歌单详情（id == uid）——顺序即官方那种（trackIds 顺序）。
        // 封面取歌单自己的 coverImgUrl；取不到就留 nil（页面走占位图，
        // ★ 2026-10-16 问题1：原先回落一个**已失效的硬编码封面 URL**，只会更糟）。
        do {
            let imported = try await NeteaseMusicAPI.shared.playlistForImport(id: "\(uid)")
            if !imported.tracks.isEmpty {
                tracks = imported.tracks
                if !imported.name.isEmpty { name = imported.name }
                coverURL = imported.coverURL
                // 问题2：创建者 = 用户自己（头像 + 昵称）
                if let n = imported.creatorName, !n.isEmpty { creatorName = n }
                if let a = imported.creatorAvatarURL, !a.isEmpty { creatorAvatarURL = a }
                isLoading = false
                return
            }
        } catch {}
        // 兜底：红心 id 列表 + 分块详情（顺序不定，仅保证不空）
        if let songs = try? await NeteaseMusicAPI.shared.likedSongs(uid: "\(uid)"), !songs.isEmpty {
            tracks = songs
            // 封面用用户「我喜欢」歌单的真实封面（歌单 id == uid）
            coverURL = try? await NeteaseMusicAPI.shared.likedPlaylistCover(uid: "\(uid)")
            isLoading = false
            return
        }
        failed = true
        isLoading = false
    }
}

// MARK: - 听歌排行（网易云「我听过的歌」）

struct NeteasePlayRecordView: View {
    private var player: PlayerCore { PlayerCore.shared }

    private enum Period: Int, CaseIterable, Identifiable {
        case week = 1   // 网易云约定：1 = 最近一周
        case all = 0    // 0 = 所有时间
        var id: Int { rawValue }
        var title: String { self == .week ? "最近一周" : "所有时间" }
    }

    /// 一条排行记录（歌曲 + 播放次数）
    struct RecordItem: Identifiable {
        let id = UUID()
        let song: MusicItem
        let playCount: Int
    }

    @State private var period: Period = .week
    @State private var items: [RecordItem] = []
    @State private var isLoading = true
    @State private var failed = false

    /// 播放全部胶囊渐变（红）
    private static let playAllGradient = [
        Color(red: 1.00, green: 0.42, blue: 0.42),
        Color(red: 0.84, green: 0.19, blue: 0.19),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 顶部行：统计范围分段 + 播放全部
                HStack {
                    Picker("", selection: $period) {
                        ForEach(Period.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)

                    Spacer()

                    Button {
                        guard !items.isEmpty else { return }
                        player.play(queue: items.map(\.song), startIndex: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                LinearGradient(colors: Self.playAllGradient,
                                               startPoint: .top, endPoint: .bottom),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(items.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if failed {
                    VStack(spacing: 10) {
                        Text("暂时拿不到听歌排行").foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("这段日子里还没有听歌记录").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    recordList
                }

                Color.clear.frame(height: 170)
            }
        }
        .navigationTitle("听歌排行")
        .task(id: period) { await load() }
    }

    /// 排行列表（序号 + 封面 + 歌名/歌手 + 播放次数）。
    private var recordList: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(items.prefix(100).enumerated()), id: \.element.id) { index, record in
                Button {
                    player.play(queue: items.map(\.song), startIndex: index)
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 28)

                        ArtworkView(url: record.song.albumCoverURL,
                                    size: 48,
                                    cornerRadius: 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.song.title)
                                .font(.system(size: 17, weight: .medium))
                                .lineLimit(1)
                            Text(record.song.artist ?? "未知艺术家")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Text("\(record.playCount) 次")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() async {
        guard let uid = NeteaseSession.shared.account?.userId else {
            failed = true
            isLoading = false
            return
        }
        isLoading = true
        failed = false
        do {
            let records = try await NeteaseMusicAPI.shared.playRecord(uid: uid, type: period.rawValue)
            items = records.map { RecordItem(song: $0.song, playCount: $0.playCount) }
        } catch {
            failed = true
        }
        isLoading = false
    }
}

// MARK: - 最近播放（网易云云端优先，本地历史兜底）

struct RecentPlaysView: View {
    @EnvironmentObject private var appState: AppState

    /// 网易云云端最近播放（登录时拉取；与 RN 版 v90 同款接口）
    @State private var cloudTracks: [MusicItem] = []
    @State private var isLoading = true

    /// 展示列表：云端优先（登录且有数据），否则本地播放历史
    private var displayTracks: [MusicItem] {
        cloudTracks.isEmpty ? appState.playHistory : cloudTracks
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayTracks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("还没有播放记录").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // ★ 2026-10-15 用户：最近播放页采用**发现页歌单版式**（大封面 + 主色底）
                WellPlaylistDetailView(
                    source: .tracks(displayTracks, name: "最近播放"),
                    coverURL: displayTracks.first?.albumCoverURL,
                    creatorName: nil)
            }
        }
        // ★ 2026-10-14 用户：进入本页导航栏会闪一下「最近播放」。
        //   根因：原先用三元标题（加载中/无数据 → "最近播放"，加载完 → ""），
        //   加载完成时标题由「最近播放」翻成空串，视觉上就是一瞬忽闪。
        //   → 标题恒为空串，页面标题完全交给子视图的大 header 呈现，不再变化。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        // 登录时优先拉网易云云端最近播放（RN 版 v90 同款 /api/play-record/song/list）；
        // 未登录或拉取失败 → 回退到本地播放历史，页面永远不空手。
        if NeteaseSession.shared.isLoggedIn,
           let cloud = try? await NeteaseMusicAPI.shared.recentSongs(limit: 100),
           !cloud.isEmpty {
            cloudTracks = cloud
        }
        isLoading = false
    }
}

// MARK: - 收藏歌曲（本地收藏列表）

/// 「收藏歌曲」：本地收藏的歌曲。
///
/// 内容原先是「音乐库」页里的「收藏歌曲」分段 —— 2026-10-14 用户要求删除音乐库页、
/// 把这一项并到「我的」页，故独立成页。
///
/// 与「我喜欢」的区别：那个是**实时**拉网易云红心歌单，这个是 App 本地收藏列表
/// （含非网易云来源的歌曲）。两者数据来源不同，按用户要求并存、不做合并。
///
/// ⚠️ 2026-10-14 用户（第二轮）：「收藏歌曲改成和**我的歌单**一样的页面」——
/// 故弃用原来的 `List + TrackRow`，改走 `WellMyPlaylistDetailView` 的
/// `.tracks` 分支（小封面 120pt + 红渐变「播放全部」+ 歌曲行），
/// 与「我喜欢」「最近播放」完全同一版式。
/// 唯一取舍：新页面的歌曲行**不再带侧滑删除**（「我的歌单」页本来就没有）——
/// 取消收藏仍可从播放页的收藏按钮操作。
struct LocalFavoriteSongsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.favoriteTracks.isEmpty {
                ProfileEmptyTip(icon: "music.note",
                                title: "还没有收藏歌曲",
                                note: "在歌曲上点收藏后会出现在这里")
            } else {
                // 本地收藏没有歌单封面 → 用**首曲封面**当 header 封面
                // （与 `WellPlaylistDetailView.dailyMode` 每日推荐同一约定）。
                WellMyPlaylistDetailView(
                    source: .tracks(name: "喜欢的歌曲",
                                    coverURL: appState.favoriteTracks.first?.albumCoverURL,
                                    creatorName: nil,
                                    tracks: appState.favoriteTracks))
            }
        }
        .navigationTitle(appState.favoriteTracks.isEmpty ? "喜欢的歌曲" : "")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 收藏专辑（网易云 api/album/sublist）

/// 「收藏专辑」：网易云账号里收藏的专辑。
struct NeteaseFavoriteAlbumsView: View {
    @State private var albums: [WellAlbumSummary] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var notLoggedIn = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if notLoggedIn {
                ProfileEmptyTip(icon: "square.stack",
                                title: "还没有登录网易云",
                                note: "登录后这里显示你在网易云收藏的专辑")
            } else if failed {
                VStack(spacing: 10) {
                    Text("暂时拿不到收藏专辑").foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty {
                ProfileEmptyTip(icon: "square.stack",
                                title: "还没有收藏专辑",
                                note: "在网易云里收藏专辑后会出现在这里")
            } else {
                ScrollView {
                    // 复用搜索页的自适应网格与卡片，尺寸逻辑不重复实现
                    WellCardGrid {
                        ForEach(albums) { album in
                            NavigationLink {
                                WellPlaylistDetailView(
                                    source: .album(id: album.id, platform: album.platform,
                                                   name: album.name, artist: album.artistName,
                                                   mid: album.albumMid),
                                    coverURL: album.picURL,
                                    creatorName: album.artistName)
                            } label: {
                                WellCoverCard(coverURL: album.picURL,
                                              title: album.name,
                                              subtitle: album.artistName,
                                              fillWidth: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                // 裸 ScrollView 不自带底色（理由同 WellMyPlaylistDetailView）
                .background(AppTheme.background)
            }
        }
        .navigationTitle("收藏专辑")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard NeteaseSession.shared.isLoggedIn else {
            notLoggedIn = true
            isLoading = false
            return
        }
        isLoading = true
        failed = false
        do {
            albums = try await NeteaseMusicAPI.shared.favoritedAlbums(limit: 200)
        } catch {
            failed = true
        }
        isLoading = false
    }
}

// MARK: - 空态提示（本文件内复用）

/// 「我的」页各子页统一的空态样式。
struct ProfileEmptyTip: View {
    let icon: String
    let title: String
    let note: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            Text(note).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 我的云盘（网易云 /api/v1/cloud/get；「我的歌单」版式）

struct NeteaseCloudView: View {
    @State private var cloudTracks: [MusicItem] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cloudTracks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "cloud")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("云盘里还没有歌曲").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 「我的歌单」同款版式（用户 2026-10-15 指定）
                WellMyPlaylistDetailView(
                    source: .tracks(name: "我的云盘",
                                    coverURL: cloudTracks.first?.albumCoverURL,
                                    creatorName: nil, tracks: cloudTracks))
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard cloudTracks.isEmpty else { return }
            cloudTracks = (try? await NeteaseMusicAPI.shared.userCloud(limit: 500)) ?? []
            isLoading = false
        }
    }
}
