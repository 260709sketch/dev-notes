import SwiftUI

// MARK: - 视图模型

@MainActor
final class WellSearchViewModel: ObservableObject {
    @Published var platform: WellSearchPlatform = .netease
    @Published var type: WellSearchType = .all
    @Published var result = WellSearchResult()
    @Published var isLoading = false

    private var loadedKey = ""

    func clear() {
        result = WellSearchResult()
        isLoading = false
    }

    func load(keyword: String) async {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { clear(); return }
        let tag = "\(platform.rawValue)|\(type.rawValue)|\(key)"
        guard tag != loadedKey else { return }

        isLoading = true
        let fetched = await SearchService.shared.search(keyword: key, platform: platform, type: type)
        // 请求期间条件若已变化则丢弃本次结果
        guard tag == "\(platform.rawValue)|\(type.rawValue)|\(key)" else { return }
        result = fetched
        loadedKey = tag
        isLoading = false
    }
}

// MARK: - 搜索页

/// 搜索 Tab：平台 / 模块分段 + 分区卡片结果（版式对齐 kumone）
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

    var body: some View {
        // 与无白边版（5d7dc59f）同构：导航容器由页面自己携带，MainTabView 不再统一包裹。
        NavigationStack {
            pageBody
        }
    }

    /// 页面主体（导航容器由本页携带）
    private var pageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if hasQuery {
                    platformPicker
                    typePicker

                    if model.isLoading && model.result.isEmpty(for: model.type) {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else if model.result.isEmpty(for: model.type) {
                        emptyResult
                    } else {
                        content
                    }
                } else {
                    emptyPrompt
                }

                // ★ 去除边距（用户 2026-10-13 指令）：底部不再加留白占位、顶部不再加 padding。
            }
        }
        // ★ 页面背景兜底（对齐用户 10-11 无白边参照版 5d7dc59f）：
        //   无白边版的搜索页写法就是 `ScrollView + .background(AppTheme.background)`；
        //   「页面不铺背景」的旧结论已证伪（kumone 真源码里页面是铺条件色背景的，
        //   只有 TabView 不铺）。裸奔会让页面区与 chrome 之间透出窗口底色 → 白色大边距。
        //   `.background` 默认 ignoresSafeAreaEdges: .all → 延伸至状态栏 / Home 指示条后面。
        .background(AppTheme.background)
        // 用系统搜索框（与 kumone 版式一致），不再自绘一行搜索框。
        // iOS 26 的 `Tab(role: .search)` 会把这里挂上的 `searchable` 接到
        // 系统搜索栏上；iOS 16–25 则落在导航栏下方，两种形态都不需要额外适配。
        .searchable(text: $searchText, prompt: "搜索歌曲、歌手、专辑、歌单")
        .onSubmit(of: .search) {
            committedQuery = searchText
        }
        .onChange(of: searchText) { newValue in
            // 400ms 防抖：输入过程中不逐字打接口
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if searchText == newValue { committedQuery = newValue }
            }
        }
        .navigationTitle(hasQuery ? "搜索：\(committedQuery)" : "搜索")
        // ⚠️ 这里**不要**加 `.navigationBarTitleDisplayMode(.inline)`：
        // kumone 搜索页用的是系统默认的**大标题**，抬头就是一行大字「搜索」。
        // 之前设成 inline 之后抬头变成导航栏里的小字，和 kumone 完全不是一套，
        // 用户一眼就看出来了。
        .task(id: taskID) {
            model.clear()
            await model.load(keyword: committedQuery)
        }
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
        .padding(.horizontal, WellSearchMetrics.contentInset)
        .padding(.top, 12)
    }

    private var typePicker: some View {
        Picker("", selection: $model.type) {
            ForEach(WellSearchType.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, WellSearchMetrics.contentInset)
    }

    // MARK: 空态提示

    private var emptyPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text("探索海量华语流行与经典音乐")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("输入歌曲、歌手、专辑或歌单关键字开始搜索")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch model.type {
        case .all: allContent
        case .songs: songList(model.result.songs)
        case .artists:
            WellCardGrid { artistCards(model.result.artists, fillWidth: true) }
                .padding(.horizontal, WellSearchMetrics.contentInset)
        case .albums:
            WellCardGrid { albumCards(model.result.albums, fillWidth: true) }
                .padding(.horizontal, WellSearchMetrics.contentInset)
        case .playlists:
            WellCardGrid { playlistCards(model.result.playlists, fillWidth: true) }
                .padding(.horizontal, WellSearchMetrics.contentInset)
        }
    }

    @ViewBuilder
    private var allContent: some View {
        if !model.result.songs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                WellSectionHeader(title: "单曲", action: { model.type = .songs })
                    .padding(.horizontal, WellSearchMetrics.contentInset)
                songList(Array(model.result.songs.prefix(6)))
            }
        }
        if !model.result.artists.isEmpty {
            WellShelf(title: "歌手", action: { model.type = .artists }) {
                artistCards(model.result.artists.prefix(8))
            }
        }
        if !model.result.albums.isEmpty {
            WellShelf(title: "专辑", action: { model.type = .albums }) {
                albumCards(model.result.albums.prefix(8))
            }
        }
        if !model.result.playlists.isEmpty {
            WellShelf(title: "歌单", action: { model.type = .playlists }) {
                playlistCards(model.result.playlists.prefix(8))
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
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: 歌曲列表

    private func songList(_ tracks: [MusicItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, item in
                Button {
                    player.play(queue: tracks, startIndex: index)
                } label: {
                    TrackRow(item: item)
                        .padding(.vertical, 6)
                        .padding(.horizontal, WellSearchMetrics.contentInset)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < tracks.count - 1 {
                    Divider().padding(.leading, WellSearchMetrics.contentInset + 58)
                }
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