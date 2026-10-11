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
    @EnvironmentObject private var player: PlayerCore
    @StateObject private var model = WellSearchViewModel()
    @State private var searchText = ""
    @State private var committedQuery = ""
    @FocusState private var focused: Bool

    private var hasQuery: Bool {
        !committedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var taskID: String {
        "\(model.platform.rawValue)|\(model.type.rawValue)|\(committedQuery)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                searchBar

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

                // 底栏（迷你播放器 + Tab 胶囊）留白：约 54 + 8 + 64 + 安全区
                Color.clear.frame(height: 150)
            }
            .padding(.top, 8)
        }
        .background(AppTheme.background)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: taskID) {
            model.clear()
            await model.load(keyword: committedQuery)
        }
    }

    // MARK: 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索歌曲、歌手、专辑、歌单", text: $searchText)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { committedQuery = searchText }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    committedQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, WellSearchMetrics.contentInset)
        .onChange(of: searchText) { newValue in
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if searchText == newValue { committedQuery = newValue }
            }
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
        .padding(.top, 80)
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