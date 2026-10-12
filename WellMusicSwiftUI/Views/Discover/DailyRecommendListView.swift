import SwiftUI

/// 每日推荐歌曲列表页（主页「每日推荐」卡片进入）。
///
/// 用户要求每日推荐**像歌单一样进列表页**，而不是点卡片直接播放：
/// 这里按歌单详情页的形态展示（封面头 + 歌曲列表 + 播放全部），
/// 点击任意一首即从该首开始播放整份日推队列。
@MainActor
struct DailyRecommendListView: View {
    @State private var tracks: [MusicItem] = []
    @State private var loading = true
    /// 进页面时先加载一次的封面（日推第一首的专辑图）
    @State private var coverURL: String?
    private var player: PlayerCore { PlayerCore.shared }

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在获取今日推荐…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("今日没有推荐歌曲")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        header
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    Section {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, item in
                            TrackRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    player.play(queue: tracks, startIndex: idx)
                                }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        // ★ 不铺背景（与 kumone 一致），交给系统 Liquid Glass 自动融合。
        .navigationTitle("每日推荐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    player.play(queue: tracks, startIndex: 0)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                }
                .disabled(tracks.isEmpty)
            }
        }
        .task {
            guard tracks.isEmpty else { return }
            tracks = (try? await NeteaseMusicAPI.shared.dailyRecommendSongs()) ?? []
            coverURL = tracks.first?.albumCoverURL
            loading = false
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            WellRemoteImage(url: coverURL, displaySize: 96)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if coverURL == nil {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.25, blue: 0.24),
                                                          Color(red: 0.85, green: 0.15, blue: 0.35)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay {
                                Text(Date().formatted(.dateTime.month().day()))
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                    }
                }
            VStack(alignment: .leading, spacing: 8) {
                Text("每日推荐")
                    .font(.title3.bold())
                Text("根据你的口味生成 · \(tracks.count) 首")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    player.play(queue: tracks, startIndex: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(tracks.isEmpty)
            }
            Spacer()
        }
    }
}
