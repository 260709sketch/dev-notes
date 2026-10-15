import SwiftUI

/// 「我的歌单」排序方式（设置项：`wellmusic.profile.playlistSort`）。
enum WellPlaylistSort: String, CaseIterable, Identifiable {
    case manual = "默认"
    case name = "名称"
    case trackCount = "歌曲数"
    var id: String { rawValue }
}

/// 我的页横滑歌单的统一条目（本地自建 + 网易云账号歌单合并后排）。
struct ProfilePlaylistItem: Identifiable {
    let id: String
    let name: String
    let coverURL: String?
    let subtitle: String
    let source: WellMyPlaylistSource
}

/// 我的 Tab —— 四分组布局（用户 2026-10-15 截图 IMG_3974 样式）。
///
/// 分组顺序（用户原话）：
///   ① 入口组：听歌排行 / 最近播放 / 网易云的我喜欢（保持现有排版，List 行样式）
///   ② 我的歌单：标题 + 查看更多，下方**横滑**选歌单（本地自建 + 网易云账号）
///   ③ 最近喜欢：标题 + 查看更多，下方一列 **5 首**（本地收藏最新在前）
///   ④ 收藏专辑：一横两个（两列网格），排数随收藏数量
///
/// 参考图为 Apple Music 音乐库风格：分组标题 = `⌄ 标题 (数量)` + 右侧「查看更多」。
struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
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

    /// 合并后的歌单条目（本地 + 网易云，按排序方式输出）。
    private var mergedPlaylists: [ProfilePlaylistItem] {
        var items: [ProfilePlaylistItem] = []
        for pl in appState.playlists {
            items.append(ProfilePlaylistItem(
                id: "local_\(pl.id.uuidString)", name: pl.name, coverURL: pl.coverURL,
                subtitle: "\(pl.tracks.count) 首", source: .local(pl)))
        }
        for pl in neteasePlaylists {
            items.append(ProfilePlaylistItem(
                id: "ne_\(pl.id)", name: pl.name, coverURL: pl.coverURL,
                subtitle: "\(pl.trackCount) 首 · 网易云",
                source: .netease(id: pl.id, name: pl.name, coverURL: pl.coverURL, creatorName: "网易云音乐")))
        }
        switch playlistSort {
        case .manual: return items
        case .name: return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .trackCount:
            return items.sorted { Int($0.subtitle.filter { $0.isNumber }) ?? 0 > Int($1.subtitle.filter { $0.isNumber }) ?? 0 }
        }
    }

    /// ⚠️ 性能铁律：不订阅 PlayerCore（20Hz 广播），只在点击时取单例发起播放。
    private var player: PlayerCore { PlayerCore.shared }

    /// 最近喜欢 = 本地收藏的最新 5 首（`favoriteTracks` 头插，最新在前）
    private var recentLikes: [MusicItem] { Array(appState.favoriteTracks.prefix(5)) }

    /// 「我的歌单」总数 = 本地自建 + 网易云账号
    private var playlistTotalCount: Int { appState.playlists.count + neteasePlaylists.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    quickEntries
                    playlistsSection
                    recentLikesSection
                    favoriteAlbumsSection

                    // 底栏（迷你播放器 52 + 间距 8 + 胶囊栏 64 + 距底 42 = 166）留白
                    Color.clear.frame(height: 170)
                }
                .padding(.top, 4)
            }
            .background(AppTheme.background)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .task { await loadContent() }
            // ★ 2026-10-15 用户：登录/退出网易云后，收藏专辑与账号歌单要跟着刷新
            //   （原先只在进页 task 拉一次，登录后回来还是空 = 「不同步」的观感来源）。
            .onChange(of: session.isLoggedIn) { _ in
                Task { await loadContent() }
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

    // MARK: - 分组① 入口：听歌排行 / 最近播放 / 我喜欢 / 设置（保持现有排版）

    private var quickEntries: some View {
        VStack(spacing: 0) {
            entryRow(icon: "chart.bar.fill", title: "听歌排行") { NeteasePlayRecordView() }
            Divider().padding(.leading, 54)
            entryRow(icon: "clock.arrow.circlepath", title: "最近播放") { RecentPlaysView() }
            Divider().padding(.leading, 54)
            entryRow(icon: "heart.text.square", title: "我喜欢的音乐") { NeteaseLikedSongsView() }
            Divider().padding(.leading, 54)
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

    @ViewBuilder
    private func entryRow<Destination: View>(
        icon: String,
        title: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(.blue)
                    .frame(width: 26)
                Text(title).font(.system(size: 16))
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
                        // ★ 2026-10-15 用户：长按删除歌单（仅本地自建；网易云账号歌单不可删）
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
                // ⚠️ 用内嵌 `List` 是为了 `swipeActions`（左滑取消收藏）——
                //    SwiftUI 的左滑菜单只在 List 里生效；`scrollDisabled` 关掉它自己的
                //    滚动（外层 ScrollView 负责滚），高度按行数精确给定。
                List {
                    ForEach(Array(recentLikes.enumerated()), id: \.offset) { index, track in
                        likeRow(track, index: index)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    appState.toggleFavorite(track)
                                } label: {
                                    Label("取消收藏", systemImage: "heart.slash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(recentLikes.count) * 64)
            }
        }
    }

    /// 歌曲行（46pt 封面 + 歌名 + 「歌手 · 平台」，点击播放）。
    /// ★ 2026-10-15 用户：标题字重与发现页歌单卡统一（medium）。
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
                        .lineLimit(1)
                    Text(likeSubtitle(track))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
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
                emptyRow(session.isLoggedIn ? "还没有收藏专辑" : "登录后显示网易云收藏的专辑")
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

    private func loadContent() async {
        isLoadingContent = true
        if session.isLoggedIn {
            async let albumsTask = NeteaseMusicAPI.shared.favoritedAlbums(limit: 200)
            if let uid = session.account?.userId {
                async let playlistsTask = NeteaseMusicAPI.shared.userPlaylists(uid: uid)
                neteasePlaylists = (try? await playlistsTask) ?? []
            }
            favoriteAlbums = (try? await albumsTask) ?? []
        }
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

/// 我的歌单：分两组 —— 本地自建 + 网易云账号歌单。
///
/// 点进去一律走 `WellMyPlaylistDetailView`（用户 2026-10-14 截图 IMG_3957 版式）。
/// 本地自建歌单没有平台属性，所以详情页里不显示「网易云音乐」平台行；
/// 账号歌单则有 —— 这正是截图里的样子。
struct MyPlaylistsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var session = NeteaseSession.shared

    /// 网易云账号歌单（未登录时保持为空，不请求）
    @State private var neteasePlaylists: [NeteaseMusicAPI.UserPlaylistItem] = []
    @State private var isLoadingNetease = false
    @State private var neteaseFailed = false

    var body: some View {
        List {
            Section("本地自建") {
                if appState.playlists.isEmpty {
                    Text("还没有自建歌单")
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
                }
            }

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
                    }
                }
            }
        }
        .navigationTitle("我的歌单")
        .task { await loadNeteasePlaylists() }
        // ★ 2026-10-15 用户：右上角新增「歌单排序」（与我的页第二分组共用同一排序设置）。
        .toolbar {
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
        case .manual: return neteasePlaylists
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
// 网易云的老规矩：每个用户的「我喜欢的音乐」歌单 id == 用户 uid，
// 所以直接复用歌单详情接口拉全部已赞歌曲，不需要单独的 like 列表接口。

struct NeteaseLikedSongsView: View {
    @State private var name = "我喜欢"
    @State private var coverURL: String?
    @State private var tracks: [MusicItem] = []
    @State private var isLoading = true
    @State private var notLoggedIn = false
    @State private var failed = false

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
                WellMyPlaylistDetailView(
                    source: .tracks(name: name, coverURL: coverURL,
                                    creatorName: "网易云音乐", tracks: tracks))
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
        // 通道 1：红心 id 列表 + 分块详情（登录态稳定，优先）
        if let songs = try? await NeteaseMusicAPI.shared.likedSongs(uid: "\(uid)"), !songs.isEmpty {
            tracks = songs
            coverURL = songs.first?.albumCoverURL
            isLoading = false
            return
        }
        // 通道 2：歌单详情（原通道兜底）
        do {
            let imported = try await NeteaseMusicAPI.shared.playlistForImport(id: "\(uid)")
            tracks = imported.tracks
            if !imported.name.isEmpty { name = imported.name }
            coverURL = imported.coverURL
        } catch {
            failed = true
        }
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
                // 复用「我的歌单」截图版式；封面取最近一首的封面
                WellMyPlaylistDetailView(
                    source: .tracks(name: "最近播放",
                                    coverURL: displayTracks.first?.albumCoverURL,
                                    creatorName: nil, tracks: displayTracks))
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
