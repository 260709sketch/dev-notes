import SwiftUI
import AVKit

// MARK: - 视图模型

@MainActor
final class WellSearchViewModel: ObservableObject {
    /// 初始平台（2026-10-16 第十一轮按用户要求回退：只保留「创建/进页时读一次
    /// 优先平台」；不要在每次 onAppear 重写用户在当前页面手选的平台）
    @Published var platform: WellSearchPlatform = WellSearchViewModel.preferredPlatform
    /// 设置 → 优先搜索平台（三大平台之一；rawValue 即展示名）
    static var preferredPlatform: WellSearchPlatform {
        let raw = UserDefaults.standard.string(forKey: "wellmusic.search.preferredPlatform")
            ?? WellSearchPlatform.netease.rawValue
        return WellSearchPlatform(rawValue: raw) ?? .netease
    }
    @Published var type: WellSearchType = .all
    @Published var result = WellSearchResult()
    @Published var isLoading = false
    /// 单曲 Tab 是否还有更多页（2026-10-15：QQ 搜索单曲单页上限 30，用户要求能下拉加载）
    @Published var songsHasMore = false

    private var loadedKey = ""
    private var currentKeyword = ""
    private var songsPage = 1
    private var isLoadingMore = false

    func clear() {
        result = WellSearchResult()
        isLoading = false
        loadedKey = ""
        songsHasMore = false
        songsPage = 1
        currentKeyword = ""
    }

    func load(keyword: String) async {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { clear(); return }
        let tag = "\(platform.rawValue)|\(type.rawValue)|\(key)"
        guard tag != loadedKey else { return }

        isLoading = true
        songsPage = 1
        currentKeyword = key
        if type == .songs {
            // 单曲 Tab 走分页通道（每页 10 首；触底自动补齐）
            let (songs, hasMore) = await SearchService.shared
                .songsPage(key, platform: platform, limit: 10, page: 1)
            guard tag == "\(platform.rawValue)|\(type.rawValue)|\(key)" else { return }
            result = WellSearchResult()
            result.songs = songs
            songsHasMore = hasMore
        } else {
            let fetched = await SearchService.shared.search(keyword: key, platform: platform, type: type)
            // 请求期间条件若已变化则丢弃本次结果
            guard tag == "\(platform.rawValue)|\(type.rawValue)|\(key)" else { return }
            result = fetched
            songsHasMore = false
        }
        loadedKey = tag
        isLoading = false
    }

    /// 单曲 Tab 触底加载下一页（每次补 10 首，滚动到列表尾部自动触发）。
    func loadMoreSongs() async {
        let tag = "\(platform.rawValue)|\(type.rawValue)|\(currentKeyword)"
        guard type == .songs, songsHasMore, !isLoadingMore, tag == loadedKey else { return }
        isLoadingMore = true
        let nextPage = songsPage + 1
        let (songs, hasMore) = await SearchService.shared
            .songsPage(currentKeyword, platform: platform, limit: 10, page: nextPage)
        // 请求期间条件变了就丢弃
        guard type == .songs,
              "\(platform.rawValue)|\(type.rawValue)|\(currentKeyword)" == loadedKey else {
            isLoadingMore = false
            return
        }
        // 按平台 id 去重后追加
        var seen = Set(result.songs.map { "\($0.source.rawValue)|\($0.platformId ?? $0.title)" })
        var added = 0
        for song in songs {
            let k = "\(song.source.rawValue)|\(song.platformId ?? song.title)"
            if seen.insert(k).inserted {
                result.songs.append(song)
                added += 1
            }
        }
        // 空页/全重复 → 直接认定没有更多，避免哨兵连环空载
        songsHasMore = hasMore && added > 0
        songsPage = nextPage
        isLoadingMore = false
    }
}

// MARK: - 搜索页

/// 搜索 Tab —— 版式按本项目搜索页规范（见 `WellSearchUI` 的常量）。
///
/// 用户 2026-10-14 第四轮给了 5 张实机截图（单曲 / 专辑 / 歌单 / 歌手 / 综合）并要求
/// 本页的结构与数值逐项对照实机截图：
///
/// ```
/// ScrollView {
///   VStack(alignment: .leading, spacing: 20) {
///     平台分段（网易云 / QQ音乐 / 酷狗）  .padding(.horizontal, 24).padding(.top, 12)
///     模块分段（综合/单曲/歌手/专辑/歌单） .padding(.horizontal, 24).padding(.top, 8)
///     结果内容 / 空态
///     底部留白
///   }
/// }
/// ```
///
/// ⚠️ 本视图**不带 `NavigationStack`**：导航容器由 `MainTabView` 统一提供。
/// 原因见 `MainTabView.page(_:_:)` —— 四个 Tab 的导航栈同时存在于视图树中时，
/// 切换可见性会让四个导航栏一起重新测量，大标题与整页都会跳一下。
struct SearchView: View {
    /// ⚠️ 刻意**不用** `@EnvironmentObject`：`PlayerCore` 每 0.05s 推一次 `currentTime`，
    /// 只要订阅了它，本页 `body` 就跟着每秒重算 20 次 —— 页面里有几十张卡时滚动直接卡死。
    /// 本页只在点击时**发起播放**、不显示任何播放状态，所以直接取单例，不订阅。
    private var player: PlayerCore { PlayerCore.shared }
    @StateObject private var model = WellSearchViewModel()
    @State private var searchText = ""
    @State private var committedQuery = ""

    private var hasQuery: Bool {
        !committedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var taskID: String {
        "\(model.platform.rawValue)|\(model.type.rawValue)|\(committedQuery)"
    }

    /// 旧版搜索界面开关（设置 → 界面；默认关 = 新版常驻自绘搜索框）。
    @AppStorage("wellmusic.search.legacyUI") private var legacySearchUI = false
    /// 正在播放的 MV（点击 MV 卡片后全屏播放）
    @State private var playingMV: WellMVSummary?

    var body: some View {
        Group {
            if legacySearchUI {
                // 旧版：系统 searchable 搜索栏（iOS 26 下进页折叠，点击展开）
                mainScroll
                    .searchable(text: $searchText, prompt: "想听点什么？")
                    .onSubmit(of: .search) {
                        committedQuery = searchText
                    }
                    .onChange(of: searchText) { newValue in
                        applyDebounce(newValue)
                    }
            } else {
                mainScroll
            }
        }
        .navigationTitle(hasQuery ? "搜索：\(committedQuery)" : "搜索")
        // ⚠️ 这里**不要**加 `.navigationBarTitleDisplayMode(.inline)`：
        // 这里用系统默认的**大标题**，抬头就是一行大字「搜索」。
        // ⚠️ 不在 task 里 clear()：清空缓存标记会让「从详情页返回」也重新请求。
        // load() 自带 loadedKey 守卫（同条件直接跳过），条件真变化时由它自己分流。
        .task(id: taskID) {
            await model.load(keyword: committedQuery)
        }
        .fullScreenCover(item: $playingMV) { mv in
            WellMVPlayerView(mv: mv)
        }
    }

    /// 主滚动内容（新旧两版共用；新版在顶部带常驻自绘搜索框）。
    /// ★ 2026-10-16 问题24：上滑浮现「回到顶部」浮钮。
    private var mainScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    WellScrollTopReporter(space: "well-search-scroll").id("well-page-top")
                    // ★ 2026-10-15 用户：新版搜索框常驻可见（旧版走系统 searchable）
                    if !legacySearchUI {
                        searchBar
                    }

                    if hasQuery {
                        platformPicker
                            .padding(.horizontal, WellSearchLayout.contentInset)
                            .padding(.top, 12)
                        typePicker
                            .padding(.horizontal, WellSearchLayout.contentInset)
                            .padding(.top, 8)

                        if model.isLoading && currentEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 300)
                        } else {
                            content
                        }
                    } else {
                        emptyPrompt
                    }

                    // 底栏（迷你播放器 52 + 间距 8 + 胶囊栏 64 + 距底 42 = 166）留白。
                    Color.clear.frame(height: 170)
                }
            }
            .coordinateSpace(name: "well-search-scroll")
            .modifier(WellScrollToTopPageModifier(
                space: "well-search-scroll", topID: "well-page-top", proxy: proxy))
        }
    }

    /// 400ms 防抖（自绘搜索框与系统 searchable 共用）。
    private func applyDebounce(_ value: String) {
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if searchText == value { committedQuery = value }
        }
    }

    // MARK: 搜索框（常驻；替代原先会折叠的系统搜索栏）

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            TextField("想听点什么？", text: $searchText)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { committedQuery = searchText }
                .onChange(of: searchText) { newValue in
                    applyDebounce(newValue)   // 400ms 防抖：输入过程中不逐字打接口
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    committedQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.secondaryBackground, in: Capsule())
        // ★ 2026-10-16 用户：「给新版的搜索框也加下阴影」
        //   （与我的页两张卡片同档阴影：黑 10% / radius 7 / y 2）
        .shadow(color: Color.black.opacity(0.10), radius: 7, x: 0, y: 2)
        .padding(.horizontal, WellSearchLayout.contentInset)
        .padding(.top, 8)
    }

    // MARK: 分段选择

    private var platformPicker: some View {
        Picker("", selection: $model.platform) {
            ForEach(WellSearchPlatform.allCases) { p in
                Text(p.rawValue).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var typePicker: some View {
        Picker("", selection: $model.type) {
            ForEach(WellSearchType.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: 空态提示

    /// 未输入关键字时的引导（48pt 图标 / spacing 16 / 顶部 60）
    private var emptyPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 60)
            Text("探索海量华语流行与经典音乐")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("输入歌曲名称、歌手名或歌单关键字开始搜索")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    /// 当前模块是否一条结果都没有
    private var currentEmpty: Bool {
        switch model.type {
        case .all: return model.result.songs.isEmpty && model.result.artists.isEmpty
        case .songs: return model.result.songs.isEmpty
        case .artists: return model.result.artists.isEmpty
        case .albums: return model.result.albums.isEmpty
        case .playlists: return model.result.playlists.isEmpty
        case .mvs: return model.result.mvs.isEmpty
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch model.type {
        case .all:
            allContent
        case .songs:
            // 单曲 Tab：首屏 20 首，触底自动补 10 首（哨兵在列表 LazyVStack 内，
            // 翻页见 ViewModel.loadMoreSongs）
            WellSearchSongList(tracks: model.result.songs,
                               onPlay: { index in
                                   player.play(queue: model.result.songs, startIndex: index)
                               },
                               onReachEnd: {
                                   Task { await model.loadMoreSongs() }
                               })
                .padding(.horizontal, WellSearchLayout.contentInset - 10)
        case .artists:
            WellSearchCardGrid { artistCards(model.result.artists) }
                .padding(.horizontal, WellSearchLayout.contentInset)
        case .albums:
            WellSearchCardGrid { albumCards(model.result.albums) }
                .padding(.horizontal, WellSearchLayout.contentInset)
        case .mvs:
            // ★ 2026-10-15 用户：MV 改为**单列列表**（一行一个）
            if model.result.mvs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(model.platform == .netease || model.platform == .qq
                         ? "没有找到相关 MV"
                         : "该平台暂不支持 MV 搜索\n请切换到「网易云」或「QQ」再搜")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 70)
            } else {
                VStack(spacing: 10) {
                    mvRows(model.result.mvs)
                }
                .padding(.horizontal, WellSearchLayout.contentInset)
            }
        case .playlists:
            WellSearchCardGrid { playlistCards(model.result.playlists) }
                .padding(.horizontal, WellSearchLayout.contentInset)
        }
    }

    /// 综合 tab：单曲（取前 6）→ 歌手 → 专辑 → 歌单，每块都能「›」进对应模块。
    @ViewBuilder
    private var allContent: some View {
        if !model.result.songs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                WellSearchSectionHeader(title: "单曲", action: { model.type = .songs })
                    .padding(.horizontal, WellSearchLayout.contentInset)
                songList(Array(model.result.songs.prefix(6)))
                    .padding(.horizontal, WellSearchLayout.contentInset - 10)
            }
        }
        if !model.result.artists.isEmpty {
            WellSearchShelf(title: "歌手", seeAll: { model.type = .artists }) {
                artistCards(model.result.artists.prefix(8))
            }
        }
        if !model.result.albums.isEmpty {
            WellSearchShelf(title: "专辑", seeAll: { model.type = .albums }) {
                albumCards(model.result.albums.prefix(8))
            }
        }
        if !model.result.playlists.isEmpty {
            WellSearchShelf(title: "歌单", seeAll: { model.type = .playlists }) {
                playlistCards(model.result.playlists.prefix(8))
            }
        }
        if currentEmpty && !model.isLoading {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("没有找到相关结果")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    // MARK: 歌曲列表

    private func songList(_ tracks: [MusicItem]) -> some View {
        WellSearchSongList(tracks: tracks) { index in
            player.play(queue: tracks, startIndex: index)
        }
    }

    // MARK: 卡片

    /// 歌手卡 → 歌手主页（★ 2026-10-14：把 `platform` 一起带过去，
    /// QQ / 酷狗 的歌手主页才拉得到歌与专辑）。
    private func artistCards(_ items: some Collection<WellArtistSummary>) -> some View {
        ForEach(Array(items)) { artist in
            NavigationLink {
                WellArtistHomeView(artistId: artist.id, artistName: artist.name,
                                   coverURL: artist.picURL, platform: artist.platform,
                                   artistMid: artist.mid)
            } label: {
                WellSearchArtistCard(artist: artist)
            }
            .buttonStyle(.plain)
        }
    }

    /// 专辑入口统一走 `WellPlaylistDetailView`（大封面歌单页样式）。
    ///
    /// 用户 2026-10-14 16:18：「搜索页面搜索出来的专辑点击进去不是歌单页面的样子」。
    /// 原本这里跳 `WellSearchDetailView`（旧版 List + 96pt 小封面），是全项目唯一的例外——
    /// 「歌手主页 → 专辑」（`WellArtistHomeView.albumShelf`）早就走的是歌单页样式。
    /// 现在两处一致；`creatorName` 传专辑歌手名，与歌手主页那处保持同款头部。
    private func albumCards(_ items: some Collection<WellAlbumSummary>) -> some View {
        ForEach(Array(items)) { album in
            NavigationLink {
                WellPlaylistDetailView(
                    source: .album(id: album.id, platform: album.platform,
                                   name: album.name, artist: album.artistName,
                                   mid: album.albumMid),
                    coverURL: album.picURL,
                    creatorName: album.artistName)
            } label: {
                WellSearchCoverCard(coverURL: album.picURL, title: album.name,
                                    subtitle: album.artistName)
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistCards(_ items: some Collection<WellPlaylistSummary>) -> some View {
        ForEach(Array(items)) { playlist in
            NavigationLink {
                playlistDestination(playlist)
            } label: {
                WellSearchCoverCard(coverURL: playlist.coverURL, title: playlist.name,
                                    subtitle: playlist.creatorName, playCount: playlist.playCount)
            }
            .buttonStyle(.plain)
        }
    }

    /// MV 行（单列列表：16:9 封面 + MV 角标 + 名称/歌手/时长）。
    private func mvRows(_ items: [WellMVSummary]) -> some View {
        ForEach(items) { mv in
            Button {
                // ★ 2026-10-15 用户：点 MV 行先收起搜索页遗留的键盘再播放
                //   （只在 tap 处收才收得掉 —— MV 页 .task 里再收已经晚了，
                //   键盘会跟着 fullScreenCover 的呈现动画闪一下）。
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                 to: nil, from: nil, for: nil)
                playingMV = mv
            } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        WellRemoteImage(url: mv.coverURL, displaySize: 320)
                            .frame(width: 128, height: 72)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("MV")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(4)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mv.name)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        Text(mv.artistName ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if mv.duration > 0 {
                            Text(Self.mvDurationText(mv.duration))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private static func mvDurationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 歌单打开目标：网易云走「我的歌单」版式；QQ / 酷狗先拉曲目再套同款版式。
    @ViewBuilder
    private func playlistDestination(_ playlist: WellPlaylistSummary) -> some View {
        switch playlist.platform {
        case .qq:
            WellRemotePlaylistView(platform: .qq, playlistId: playlist.id,
                                   name: playlist.name, coverURL: playlist.coverURL)
        case .kugou:
            WellRemotePlaylistView(platform: .kugou, playlistId: playlist.id,
                                   name: playlist.name, coverURL: playlist.coverURL)
        default:
            WellMyPlaylistDetailView(
                source: .netease(id: playlist.id, name: playlist.name,
                                 coverURL: playlist.coverURL,
                                 creatorName: playlist.creatorName))
        }
    }
}

/// MV 全屏播放页（AVPlayer；进入时暂停后台音乐）。
struct WellMVPlayerView: View {
    let mv: WellMVSummary
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failed = false
    /// ★ 2026-10-16 用户问题22：顶部标题/关闭钮跟随控制条显隐
    ///（点一下出现，再点消失；4 秒无操作自动隐藏，不挡视野）
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if failed {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 42))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("暂时拿不到这个 MV")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack(alignment: .top) {
                    // 左侧占位（与右上关闭钮等宽），保证标题真正居中
                    Color.clear.frame(width: 34, height: 34)

                    Spacer(minLength: 8)

                    // 标题块**居中**（用户 2026-10-15）；
                    // ★ 问题22：过长自动截断留 …（maxWidth 限制，不碰两侧按钮）
                    VStack(alignment: .center, spacing: 2) {
                        Text(mv.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(mv.artistName ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 8)

                    Spacer(minLength: 8)

                    // 关闭钮放**右上角**（用户 2026-10-16：「退出按钮移到右边」）
                    Button {
                        player?.pause()
                        // ⚠️ 先复位方向锁再关（否则关闭动画期间系统仍按横屏评估，
                        //    onDisappear 里再改会晚一拍 —— 「离开后一直横屏」的根因）
                        restorePortrait()
                        closeAndDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.42), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: controlsVisible)
                .allowsHitTesting(controlsVisible)
                Spacer()
            }
        }
        .statusBarHidden()
        .contentShape(Rectangle())
        .onTapGesture {
            controlsVisible.toggle()
            scheduleHide()
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .task {
            // ★ 2026-10-15 用户：进 MV 页先收起搜索页遗留的键盘
            //   （双保险：tap 处已收过一次，这里兜住系统搜索栏等其它入口）
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                             to: nil, from: nil, for: nil)
            // ★ 2026-10-15 用户：MV 自动横屏（放开 App 方向锁 + 请求横屏）
            enterLandscape()
            // 播放 MV 时暂停后台音乐
            PlayerCore.shared.pause()
            // ★ 2026-10-15 用户：MV 起播记入「近期播放」MV 段（纯本地）
            AppState.shared.recordMVPlay(mv)
            // mvURL 返回 String?，try? 会再包一层 → ?? nil 展平
            // ★ 2026-10-16 问题6：按平台分流取 MV 地址（QQ 走 MvUrlProxy，其余走网易云）
            let link: String?
            switch mv.platform {
            case .qq:
                link = (try? await QQMusicAPI.shared.mvURL(vid: mv.id)) ?? nil
            default:
                link = (try? await NeteaseMusicAPI.shared.mvURL(id: mv.id)) ?? nil
            }
            guard let link, let url = URL(string: link) else {
                failed = true
                return
            }
            let avPlayer = AVPlayer(url: url)
            player = avPlayer
            avPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            restorePortrait()   // 双保险（点 X 之外的所有关闭路径）
        }
    }

    // MARK: 关闭

    /// 关 MV 页：先等方向复位动画走完再 dismiss，关完再强制根窗口重新布局。
    ///
    /// ★ 2026-10-15 用户：「播放 MV 退出来到发现页或其他页面会有些歌单和按钮错乱」——
    /// 根因是横屏↔竖屏切换与 fullScreenCover 的 dismiss 挤在同一帧：
    /// 底层页仍按横屏尺寸测量过，dismiss 后没有重新布局，货架/按钮就停留在
    /// 错误的几何位置上。两招合用：① 把 dismiss 推迟到旋转动画之后；
    /// ② dismiss 后对场景的窗口强制 setNeedsLayout + layoutIfNeeded，
    /// 让底层 SwiftUI 树按竖屏重新测量。
    /// 4 秒无操作自动隐藏顶部条（用户点按会重置计时）
    private func scheduleHide() {
        hideTask?.cancel()
        controlsVisible = true
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func closeAndDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [dismiss] in
            dismiss()
            Self.forceRootRelayout()
        }
    }

    /// 强制前台场景的窗口重新布局（清掉横屏测量残留）。
    private static func forceRootRelayout() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            for window in scene.windows {
                window.setNeedsLayout()
                window.layoutIfNeeded()
            }
        }
    }

    // MARK: 方向控制

    private func enterLandscape() {
        WellMusicAppDelegate.orientationLock = .landscape
        Self.applyOrientation(.landscape)
    }

    private func restorePortrait() {
        WellMusicAppDelegate.orientationLock = .portrait
        Self.applyOrientation(.portrait)
    }

    /// 应用方向：请求几何更新 + 通知系统重新评估支持方向。
    /// ⚠️ 只改 `orientationLock` 不够：iOS 16+ 需要显式 requestGeometryUpdate；
    ///    同时给当前顶层控制器 setNeedsUpdateOfSupportedInterfaceOrientations，
    ///    让 fullScreenCover 呈现层也按新方向重新评估（否则一直横屏）。
    private static func applyOrientation(_ mask: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        if #available(iOS 16.0, *) {
            let root = scene?.keyWindow?.rootViewController
            root?.setNeedsUpdateOfSupportedInterfaceOrientations()
            var top = root
            while let presented = top?.presentedViewController { top = presented }
            top?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

/// QQ / 酷狗歌单的打开桥：拉取曲目后套「我的歌单」同款版式。
struct WellRemotePlaylistView: View {
    let platform: MusicSource
    let playlistId: String
    let name: String
    let coverURL: String?
    @State private var tracks: [MusicItem]?

    var body: some View {
        Group {
            if let tracks {
                if tracks.isEmpty {
                    ProfileEmptyTip(icon: "music.note.list",
                                    title: "暂时拿不到这个歌单",
                                    note: "换个网络环境再试试")
                } else {
                    WellMyPlaylistDetailView(
                        source: .tracks(name: name, coverURL: coverURL,
                                        creatorName: platform.displayName, tracks: tracks))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard tracks == nil else { return }
            switch platform {
            case .qq:
                tracks = ((try? await QQMusicAPI.shared.playlistDetail(dissTid: playlistId))?.tracks) ?? []
            case .kugou:
                tracks = ((try? await KugouMusicAPI.shared.playlistSongs(specialId: playlistId))) ?? []
            default:
                tracks = []
            }
        }
    }
}

#Preview {
    SearchView()
}
