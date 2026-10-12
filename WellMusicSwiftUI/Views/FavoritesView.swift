import SwiftUI

/// 收藏 Tab：顶部切换 收藏歌曲 / 收藏歌单 / 播放历史，入口自建歌单
///
/// ⚠️ 本视图**不带 `NavigationStack`**：导航容器由 `MainTabView` 统一提供。
/// 原因见 `MainTabView.page(_:_:)` —— 四个 Tab 的导航栈在视图树里同时存在时，
/// 切换可见性会让四个导航栏一起重新测量，大标题与整页都会跳一下。
struct FavoritesView: View {
    @EnvironmentObject private var appState: AppState
    /// ⚠️ 刻意**不用** `@EnvironmentObject`：`PlayerCore` 每 0.05s 推一次 `currentTime`，
    /// 只要订阅了它，本页 `body` 就跟着每秒重算 20 次 —— 页面里有几十张卡时滚动直接卡死。
    /// 本页只在点击时**发起播放**、不显示任何播放状态，所以直接取单例，不订阅。
    private var player: PlayerCore { PlayerCore.shared }
    @State private var segment: Segment = .tracks

    enum Segment: String, CaseIterable {
        case tracks = "收藏歌曲"
        case playlists = "收藏歌单"
        case history = "播放历史"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            List {
                switch segment {
                case .tracks: trackRows(appState.favoriteTracks)
                case .history: trackRows(appState.playHistory)
                case .playlists: playlistRows
                }
            }
            .listStyle(.plain)
            // ★ 系统 plain List 背景自动延伸到 chrome 区域下面，不手动干预。
        }
        .navigationTitle("音乐库")
    }

    @ViewBuilder
    private func trackRows(_ tracks: [MusicItem]) -> some View {
        if tracks.isEmpty {
            if #available(iOS 17.0, *) {
                ContentUnavailableView("还没有歌曲", systemImage: "music.note",
                                       description: Text("播放过的歌曲会出现在这里"))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("还没有歌曲").font(.headline)
                    Text("播放过的歌曲会出现在这里").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        } else {
            ForEach(tracks) { item in
                TrackRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(queue: tracks, startIndex: tracks.firstIndex(of: item) ?? 0) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            remove(item)
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private var playlistRows: some View {
        Group {
            if appState.favoritePlaylists.isEmpty {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView("还没有收藏歌单", systemImage: "music.note.list")
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("还没有收藏歌单").font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                ForEach(appState.favoritePlaylists) { pl in
                    HStack(spacing: 12) {
                        ArtworkView(url: pl.coverURL, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pl.name).font(.body).lineLimit(1)
                            Text("\(pl.trackCount) 首 · \(pl.source.displayName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func remove(_ item: MusicItem) {
        appState.favoriteTracks.removeAll { MusicItem.isSame($0, item) }
        appState.playHistory.removeAll { MusicItem.isSame($0, item) }
    }
}

/// 通用歌曲行
struct TrackRow: View {
    @EnvironmentObject private var appState: AppState
    let item: MusicItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.albumCoverURL, size: 46, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body).lineLimit(1)
                Text(item.artist ?? "未知艺术家")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    FavoritesView()
}