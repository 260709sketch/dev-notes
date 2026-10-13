import SwiftUI

// MARK: - 视图模型（kumone 全搬：按模块惰性加载 + 平台/关键词切换全清）

@MainActor
final class WellSearchViewModel: ObservableObject {
    @Published var platform: WellSearchPlatform = .netease {
        didSet {
            // 平台切换：清空已加载标签和所有结果，强制重新搜索
            guard oldValue != platform else { return }
            loadedTabs.removeAll()
            songs = []
            artists = []
            albums = []
            playlists = []
        }
    }
    /// 模块切换时清空已加载标签，强制重新搜索（kumone 同款语义）
    @Published var type: WellSearchType = .all {
        didSet { loadedTabs.removeAll() }
    }

    /// 当前生效的搜索词（由视图层防抖后 `setQuery` 写入，不直接 @Published）
    private(set) var query = ""

    @Published var songs: [MusicItem] = []
    @Published var artists: [WellArtistSummary] = []
    @Published var albums: [WellAlbumSummary] = []
    @Published var playlists: [WellPlaylistSummary] = []
    @Published var isLoading = false
    @Published var loadedTabs: Set<WellSearchType> = []

    /// 关键词变化：全清 + 强制重搜
    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        loadedTabs.removeAll()
        songs = []
        artists = []
        albums = []
        playlists = []
    }

    /// 当前模块是否无结果（综合 = 四类全空）
    func currentEmpty(for type: WellSearchType) -> Bool {
        switch type {
        case .all: return songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
        case .songs: return songs.isEmpty
        case .artists: return artists.isEmpty
        case .albums: return albums.isEmpty
        case .playlists: return playlists.isEmpty
        }
    }

    /// 按模块惰性加载：已拉过的模块直接跳过（kumone loadedTabs 语义）
    func load(tab: WellSearchType) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !loadedTabs.contains(tab) else { return }
        isLoading = true
        defer { isLoading = false }
        loadedTabs.insert(tab)

        switch tab {
        case .all:
            // 综合页：四路并发取样（与 kumone async let 同构）
            async let songsTask = SearchService.shared.search(keyword: trimmed, platform: platform, type: .songs, limit: 12)
            async let artistsTask = SearchService.shared.search(keyword: trimmed, platform: platform, type: .artists, limit: 10)
            async let albumsTask = SearchService.shared.search(keyword: trimmed, platform: platform, type: .albums, limit: 10)
            async let playlistsTask = SearchService.shared.search(keyword: trimmed, platform: platform, type: .playlists, limit: 10)
            let (s, ar, al, pl) = await (songsTask, artistsTask, albumsTask, playlistsTask)
            songs = s.songs
            artists = ar.artists
            albums = al.albums
            playlists = pl.playlists
        case .songs:
            // 单曲页全量：网易云 100，QQ/酷狗 50（kumone 同款配额）
            let limit = platform == .netease ? 100 : 50
            let fetched = await SearchService.shared.search(keyword: trimmed, platform: platform, type: .songs, limit: limit)
            songs = fetched.songs
        case .artists:
            let fetched = await SearchService.shared.search(keyword: trimmed, platform: platform, type: .artists, limit: 50)
            artists = fetched.artists
        case .albums:
            let fetched = await SearchService.shared.search(keyword: trimmed, platform: platform, type: .albums, limit: 50)
            albums = fetched.albums
        case .playlists:
            // QQ/酷狗无歌单搜索（SearchService 内部也会挡），保持空
            let fetched = await SearchService.shared.search(keyword: trimmed, platform: platform, type: .playlists, limit: 50)
            playlists = fetched.playlists
        }
    }
}

// MARK: - 搜索页

/// 搜索 Tab —— kumone `SearchView` 全量移植（该页为用户原创，授权全搬）。
///
/// 结构：搜索框 → 平台分段 → 模块分段 → 结果（综合 = 单曲列表 + 歌手/专辑/歌单货架）。
/// 关键词 400ms 防抖；切模块惰性加载；切平台/关键词全清重搜。
///
/// ⚠️ 不订阅 PlayerCore（只用它「发起播放」；订阅会让搜索列表随
/// 20Hz 播放时钟每秒重算 20 次 → 滑动掉帧）。
struct SearchView: View {
    @StateObject private var model = WellSearchViewModel()
    @State private var searchText = ""
    @State private var committedQuery = ""
    @FocusState private var focused: Bool

    private var hasQuery: Bool {
        !committedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    searchBar

                    if hasQuery {
                        // 平台分段（网易云 / QQ音乐 / 酷狗）—— kumone SearchView 同款双分段结构
                        platformPicker
                        typePicker

                        if model.isLoading && model.currentEmpty(for: model.type) {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 300)
                        } else {
                            tabContent
                        }
                    } else {
                        emptyPrompt
                    }

                    // 底栏（迷你播放器 + Tab 胶囊）留白：约 54 + 8 + 64 + 安全区
                    Color.clear.frame(height: 150)
                }
                .padding(.top, 8)
            }
            .background(AppTheme.background)
            .navigationTitle(hasQuery ? "搜索：\(committedQuery)" : "搜索")
            .navigationBarTitleDisplayMode(.inline)
            // 关键词 / 平台变化：全清重搜（防抖 400ms 由 searchBar 内部完成）
            .task(id: "\(model.platform.rawValue)|\(committedQuery)") {
                model.setQuery(committedQuery)
                await model.load(tab: model.type)
            }
            // 模块变化：惰性加载该模块（已加载则跳过）
            .task(id: model.type) {
                await model.load(tab: model.type)
            }
        }
    }

    // MARK: 搜索框

    /// 搜索框 + 红色 Cancel（对照 kumone 截图：有输入时才出现，点击清空并收起键盘）
    private var searchBar: some View {
        HStack(spacing: 12) {
            WellSearchField(
                text: $searchText,
                isFocused: $focused,
                onSubmit: { committedQuery = searchText },
                onClear: { searchText = "" }
            )

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    committedQuery = ""
                    focused = false
                } label: {
                    Text("Cancel")
                        .font(.system(size: 16))
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, WellSearchMetrics.contentInset)
        .animation(.easeInOut(duration: 0.15), value: searchText.isEmpty)
        .onChange(of: searchText) { newValue in
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if searchText == newValue { committedQuery = newValue }
            }
        }
    }

    // MARK: 分段选择

    private var platformPicker: some View {
        WellSegmentedControl(items: WellSearchPlatform.allCases,
                             title: { $0.rawValue },
                             selection: $model.platform)
            .padding(.horizontal, WellSearchMetrics.contentInset)
    }

    private var typePicker: some View {
        WellSegmentedControl(items: WellSearchType.allCases,
                             title: { $0.rawValue },
                             selection: $model.type)
            .padding(.horizontal, WellSearchMetrics.contentInset)
    }

    // MARK: 空态提示

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

    // MARK: 结果区

    @ViewBuilder
    private var tabContent: some View {
        switch model.type {
        case .all:
            allContent
            // 综合页四类全空且不在加载 → 明确的「无结果」提示（kumone 同款）
            if model.currentEmpty(for: .all), !model.isLoading {
                emptyResult
                    .frame(minHeight: 300)
            }
        case .songs:
            songList(model.songs)
        case .artists:
            WellCardGrid { artistCards(model.artists, fillWidth: true) }
                .padding(.horizontal, WellSearchMetrics.contentInset)
        case .albums:
            WellCardGrid { albumCards(model.albums, fillWidth: true) }
                .padding(.horizontal, WellSearchMetrics.contentInset)
        case .playlists:
            if model.playlists.isEmpty, !model.isLoading {
                emptyResult
                    .frame(minHeight: 300)
            } else {
                WellCardGrid { playlistCards(model.playlists, fillWidth: true) }
                    .padding(.horizontal, WellSearchMetrics.contentInset)
            }
        }
    }

    @ViewBuilder
    private var allContent: some View {
        if !model.songs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                WellSectionHeader(title: "单曲") {
                    model.type = .songs
                }
                .padding(.horizontal, WellSearchMetrics.contentInset)
                songList(Array(model.songs.prefix(6)))
            }
        }
        if !model.artists.isEmpty {
            WellShelf(title: "歌手", action: { model.type = .artists }) {
                artistCards(model.artists.prefix(8))
            }
        }
        if !model.albums.isEmpty {
            WellShelf(title: "专辑", action: { model.type = .albums }) {
                albumCards(model.albums.prefix(8))
            }
        }
        if !model.playlists.isEmpty {
            WellShelf(title: "歌单", action: { model.type = .playlists }) {
                playlistCards(model.playlists.prefix(8))
            }
        }
    }

    private var emptyResult: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("没有找到相关结果")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 歌曲列表

    /// 歌曲列表（对照 kumone 截图：行间**无分隔线**，干净列表）
    private func songList(_ tracks: [MusicItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, item in
                Button {
                    PlayerCore.shared.play(queue: tracks, startIndex: index)
                } label: {
                    WellSearchTrackRow(item: item)
                        .padding(.horizontal, WellSearchMetrics.contentInset)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 卡片

    private func artistCards(_ items: some Collection<WellArtistSummary>, fillWidth: Bool = false) -> some View {
        ForEach(Array(items)) { artist in
            NavigationLink {
                WellSearchDetailView(
                    source: .artist(id: artist.id, platform: artist.platform, name: artist.name),
                    coverURL: artist.picURL)
            } label: {
                WellArtistCard(artist: artist, fillWidth: fillWidth)
            }
            .buttonStyle(.plain)
        }
    }

    private func albumCards(_ items: some Collection<WellAlbumSummary>, fillWidth: Bool = false) -> some View {
        ForEach(Array(items)) { album in
            NavigationLink {
                WellSearchDetailView(
                    source: .album(id: album.id, platform: album.platform,
                                   name: album.name, artist: album.artistName),
                    coverURL: album.picURL)
            } label: {
                WellCoverCard(coverURL: album.picURL, title: album.name,
                              subtitle: album.artistName, fillWidth: fillWidth)
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistCards(_ items: some Collection<WellPlaylistSummary>, fillWidth: Bool = false) -> some View {
        ForEach(Array(items)) { playlist in
            NavigationLink {
                WellSearchDetailView(
                    source: .playlist(id: playlist.id, platform: .netease, name: playlist.name),
                    coverURL: playlist.coverURL)
            } label: {
                WellCoverCard(coverURL: playlist.coverURL, title: playlist.name,
                              subtitle: playlist.creatorName, playCount: playlist.playCount,
                              fillWidth: fillWidth)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    SearchView()
}
