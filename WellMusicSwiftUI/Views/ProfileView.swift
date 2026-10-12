import SwiftUI

/// 我的 Tab：用户入口 + 自建歌单 + 设置入口（后续轮次填充子页面）
///
/// ⚠️ 本视图**不带 `NavigationStack`**：导航容器由 `MainTabView` 统一提供。
/// 原因见 `MainTabView.page(_:_:)` —— 四个 Tab 的导航栈同时存在于视图树中时，
/// 切换可见性会让四个导航栏一起重新测量，大标题与整页都会跳一下。
/// 本页里的 `NavigationLink` 依赖外层那个导航栈，去掉本层的栈后照常工作。
struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingSettings = false

    var body: some View {
        List {
            Section {
                NeteaseAccountCard()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink { MyPlaylistsView() } label: {
                    Label("我的歌单", systemImage: "music.note.list")
                }
                NavigationLink { Text("收藏专辑（开发中）").frame(maxWidth: .infinity, alignment: .leading) } label: {
                    Label("收藏专辑", systemImage: "square.stack")
                }
                NavigationLink { Text("网易云已赞歌曲（开发中）") .frame(maxWidth: .infinity, alignment: .leading) } label: {
                    Label("网易云我喜欢", systemImage: "heart.text.square")
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
        .navigationTitle("我的")
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

/// 自建歌单列表
struct MyPlaylistsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingCreate = false

    var body: some View {
        List {
            if appState.playlists.isEmpty {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView("暂无歌单", systemImage: "music.note.list",
                                           description: Text("点击右上角新建歌单"))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("暂无歌单").font(.headline)
                        Text("点击右上角新建歌单").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                ForEach(appState.playlists) { pl in
                    NavigationLink {
                        PlaylistDetailView(playlist: pl)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: pl.coverURL, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pl.name).font(.body).lineLimit(1)
                                Text("\(pl.tracks.count) 首")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    appState.playlists.remove(atOffsets: offsets)
                }
            }
        }
        .navigationTitle("我的歌单")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCreate = true
                } label: {
                    Image(systemName: "plus")
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
}

/// 歌单详情
struct PlaylistDetailView: View {
    @EnvironmentObject private var player: PlayerCore
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