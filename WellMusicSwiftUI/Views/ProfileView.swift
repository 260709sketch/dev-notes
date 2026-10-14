import SwiftUI

/// 我的 Tab：网易云账号登录入口（导航栏右侧）+ 自建歌单 + 网易云内容入口 + 设置入口
struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var session = NeteaseSession.shared
    @State private var showingSettings = false
    /// 点头像 → 底部弹出账号设置（未登录 = 登录入口；已登录 = 账号详情/退出登录）
    @State private var showingAccount = false
    /// 大标题被导航栏完全盖住 → 把「我的」收进导航栏（Apple Music 折叠行为）
    @State private var titleCollapsed = false
    /// 大标题行静止时的 global minY（首帧量到；折叠阈值以此为基准，与机型安全区高度无关）
    @State private var titleRestingMinY: CGFloat? = nil

    var body: some View {
        NavigationStack {
            List {
                largeTitleSection

                Section {
                    NavigationLink { MyPlaylistsView() } label: {
                        Label("我的歌单", systemImage: "music.note.list")
                    }
                    NavigationLink { NeteaseFavoriteAlbumsView() } label: {
                        Label("收藏专辑", systemImage: "square.stack")
                    }
                    // 本地收藏列表（原先在已删除的「音乐库」页里）
                    NavigationLink { LocalFavoriteSongsView() } label: {
                        Label("收藏歌曲", systemImage: "music.note")
                    }
                }

                Section("网易云") {
                    NavigationLink { NeteaseLikedSongsView() } label: {
                        Label("我喜欢", systemImage: "heart.text.square")
                    }
                    NavigationLink { NeteasePlayRecordView() } label: {
                        Label("听歌排行", systemImage: "chart.bar.fill")
                    }
                    NavigationLink { RecentPlaysView() } label: {
                        Label("最近播放", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                            .foregroundStyle(.primary)
                    }
                }
            }
            // 大标题折叠时导航栏才显示「我的」；静止时留空（大标题由 largeTitleSection 自绘）
            .navigationTitle(titleCollapsed ? "我的" : "")
            // ★ 2026-10-14 用户：头像要像 Apple Music 那样钉在**导航栏右上角**
            //   （参考截图 IMG_3962），不是和大标题「我的」挤在同一行（IMG_3961 红圈标出的错误位置）。
            //   根因：大标题（.large）模式下 `.topBarTrailing` 的 toolbar item 会被系统
            //   渲染进**大标题那一行**；只有 `.inline` 模式才固定在导航栏条里。
            //   代价：系统大标题不能用了 → 由 `largeTitleSection` 在列表首行自绘
            //   （34pt bold，随内容滚动），滚过后由 titleCollapsed 收进导航栏。
            .navigationBarTitleDisplayMode(.inline)
            // ★ 2026-10-14 用户：登录卡片移除，登录入口放到「我的」大标题右侧。
            //   未登录显示与 dock 栏「我的」同款人形图标，登录后显示网易云头像。
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    accountEntryButton
                }
            }
            // 量大标题行的滚动位置：完全滚进导航栏下方 → 折叠出导航栏标题
            .onPreferenceChange(ProfileTitleOffsetKey.self) { minY in
                guard minY > 0 else { return }
                if titleRestingMinY == nil { titleRestingMinY = minY }
                guard let rest = titleRestingMinY else { return }
                // 阈值 ≈ 导航栏 44 + 标题行高 41 ≈ 46：标题被完全盖住即折叠
                let shouldCollapse = (rest - minY) > 46
                if shouldCollapse != titleCollapsed {
                    withAnimation(.easeInOut(duration: 0.16)) { titleCollapsed = shouldCollapse }
                }
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

    // MARK: 大标题（Apple Music 版式）

    /// 「我的」大标题：34pt bold、左缘与下方卡片对齐、随内容滚动。
    /// 行内挂 GeometryReader 上报 global minY（`ProfileTitleOffsetKey`），
    /// 由 body 的 onPreferenceChange 判定折叠时机。
    private var largeTitleSection: some View {
        Section {
            Text("我的")
                .font(.system(size: 34, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                // insetGrouped 里行的布局框 = 卡片框，leading 0 = 贴卡片左缘
                // （= 距屏幕 16pt，与系统大标题、卡片左缘三者对齐）
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ProfileTitleOffsetKey.self,
                            value: geo.frame(in: .global).minY
                        )
                    }
                )
        }
    }

    // MARK: 登录入口（大标题右侧图标）

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

/// 「我的」页大标题行的滚动位置（global minY）：
/// 用来判定大标题是否已被导航栏完全盖住 —— 盖住就把「我的」收进导航栏
/// （Apple Music 的大标题折叠行为，见 `ProfileView.titleCollapsed`）。
private struct ProfileTitleOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
    @State private var showingCreate = false

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
                    ForEach(appState.playlists) { pl in
                        NavigationLink {
                            WellMyPlaylistDetailView(source: .local(pl))
                        } label: {
                            row(name: pl.name, coverURL: pl.coverURL,
                                subtitle: "\(pl.tracks.count) 首")
                        }
                    }
                    .onDelete { offsets in
                        appState.playlists.remove(atOffsets: offsets)
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
                        ForEach(neteasePlaylists) { pl in
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    // 导入歌单（网易云 / QQ 音乐链接 → 本地歌单）
                    NavigationLink {
                        PlaylistImportView()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Button {
                        showingCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .alert("新建歌单", isPresented: $showingCreate) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") { createPlaylist() }
            Button("取消", role: .cancel) {}
        }
    }

    @State private var newPlaylistName = ""

    private func createPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        appState.playlists.insert(Playlist(name: name), at: 0)
        newPlaylistName = ""
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
                tipView("还没有喜欢的歌曲", "在网易云里给歌曲点红心后会出现在这里")
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
    @Environment(\.colorScheme) private var colorScheme

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

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                VStack(spacing: 10) {
                    Text("暂时拿不到听歌排行").foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("这段日子里还没有听歌记录").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { record in
                    HStack(spacing: 12) {
                        TrackRow(item: record.song)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.play(queue: items.map(\.song),
                                            startIndex: items.firstIndex { $0.id == record.id } ?? 0)
                            }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(record.playCount)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text("次")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(AppTheme.accent)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("听歌排行")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            Picker("统计范围", selection: $period) {
                ForEach(Period.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // plain List 系统底色是 systemBackground（浅白/深黑），Picker 遮底用同色才连续
            .background(colorScheme == .dark ? Color.black : Color(uiColor: .systemBackground))
        }
        .task(id: period) { await load() }
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
        .navigationTitle(isLoading || displayTracks.isEmpty ? "最近播放" : "")
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
struct LocalFavoriteSongsView: View {
    @EnvironmentObject private var appState: AppState
    /// 只发起播放、不显示播放状态 → 取单例引用，不订阅（理由同 PlaylistDetailView）。
    private var player: PlayerCore { PlayerCore.shared }

    var body: some View {
        Group {
            if appState.favoriteTracks.isEmpty {
                ProfileEmptyTip(icon: "music.note",
                                title: "还没有收藏歌曲",
                                note: "在歌曲上点收藏后会出现在这里")
            } else {
                List(appState.favoriteTracks) { item in
                    TrackRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(queue: appState.favoriteTracks,
                                        startIndex: appState.favoriteTracks.firstIndex(of: item) ?? 0)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                appState.favoriteTracks.removeAll { MusicItem.isSame($0, item) }
                            } label: {
                                Label("移除", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("收藏歌曲")
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
                                                   name: album.name, artist: album.artistName),
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
