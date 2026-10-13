import SwiftUI

/// 我的 Tab：用户入口 + 自建歌单 + 设置入口（后续轮次填充子页面）
///
/// ⚠️ 本视图**不带 `NavigationStack`**：导航容器由 `MainTabView` 统一提供。
/// 原因见 `MainTabView.page(_:_:)` —— 四个 Tab 的导航栈同时存在于视图树中时，
/// 切换可见性会让四个导航栏一起重新测量，大标题与整页都会跳一下。
/// 本页里的 `NavigationLink` 依赖外层那个导航栈，去掉本层的栈后照常工作。
struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
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
        // ★ 逐字对齐 kumone `LocalPlaylistView.swift:91` 的写法：
        //   浅灰页面底色**必须显式铺满全屏**（`background` 默认
        //   ignoresSafeAreaEdges: .all → 延伸到状态栏 / Home 指示条后面）。
        //   只靠 List 的系统背景不延伸进 TabView 的 chrome 区 ——
        //   浅灰页面 + 白色 chrome 区 = 顶部/底部「白色矩形」（用户 12:38 截图实锤）。
        .scrollContentBackground(.hidden)
        .background(colorScheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
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
    /// ⚠️ 刻意**不用** `@EnvironmentObject`：`PlayerCore` 每 0.05s 推一次 `currentTime`，
    /// 只要订阅了它，本页 `body` 就跟着每秒重算 20 次 —— 页面里有几十张卡时滚动直接卡死。
    /// 本页只在点击时**发起播放**、不显示任何播放状态，所以直接取单例，不订阅。
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
    /// 只发起播放、不显示播放状态 → 取单例引用，不订阅（理由同 PlaylistDetailView）。
    private var player: PlayerCore { PlayerCore.shared }

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
                List(tracks) { item in
                    TrackRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(queue: tracks, startIndex: tracks.firstIndex(of: item) ?? 0)
                        }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("我喜欢")
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
    /// 只发起播放、不显示播放状态 → 取单例引用，不订阅（理由同 PlaylistDetailView）。
    private var player: PlayerCore { PlayerCore.shared }
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
                List(displayTracks) { item in
                    TrackRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(queue: displayTracks,
                                        startIndex: displayTracks.firstIndex(of: item) ?? 0)
                        }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("最近播放")
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