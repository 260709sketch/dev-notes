import SwiftUI

/// 收藏 Tab：顶部切换 收藏歌曲 / 收藏歌单 / 播放历史，入口自建歌单
struct FavoritesView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerCore
    @State private var segment: Segment = .tracks

    enum Segment: String, CaseIterable {
        case tracks = "收藏歌曲"
        case playlists = "收藏歌单"
        case history = "播放历史"
    }

    var body: some View {
        NavigationStack {
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
            }
            .navigationTitle("收藏")
        }
    }

    @ViewBuilder
    private func trackRows(_ tracks: [MusicItem]) -> some View {
        if tracks.isEmpty {
            ContentUnavailableView("还没有歌曲", systemImage: "music.note",
                                   description: Text("播放过的歌曲会出现在这里"))
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
                ContentUnavailableView("还没有收藏歌单", systemImage: "music.note.list")
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