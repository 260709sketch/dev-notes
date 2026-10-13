import SwiftUI

/// 每日推荐列表页 —— 对齐 kumone `DailySongsView` 的结构与观感，代码原创。
///
/// 结构：顶部大封面 header（首曲封面 + 底部渐变 + 日期/标题/副标题 + 播放全部胶囊）
/// → 歌曲列表（`WellSearchTrackRow`）。
///
/// ⚠️ 不订阅 PlayerCore；发起播放用 `PlayerCore.shared` 单例。
struct DailyRecommendView: View {
    @State private var tracks: [MusicItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                    .padding(.horizontal, WellSearchMetrics.contentInset)
                    .padding(.top, 12)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if let errorMessage {
                    errorState(errorMessage)
                } else if tracks.isEmpty {
                    emptyState
                } else {
                    songList
                }

                Color.clear.frame(height: 170)
            }
        }
        .background(AppTheme.background)
        .navigationTitle("每日推荐")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard tracks.isEmpty else { return }
            await load()
        }
    }

    // MARK: 大封面 header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            WellRemoteImage(url: tracks.first?.albumCoverURL, displaySize: 640)
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()

            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 24, weight: .medium))
                        Text(dateString)
                            .font(.system(size: 14, weight: .medium))
                            .opacity(0.85)
                    }
                    Text("每日推荐")
                        .font(.system(size: 30, weight: .bold))
                    Text("根据你的音乐口味 · 每天 6:00 更新")
                        .font(.system(size: 12))
                        .opacity(0.72)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)

                Spacer()

                Button {
                    guard !tracks.isEmpty else { return }
                    PlayerCore.shared.play(queue: tracks, startIndex: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(AppTheme.accent, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: 列表

    private var songList: some View {
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

    // MARK: 状态

    private var dateString: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return fmt.string(from: .now)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await load() }
            } label: {
                Text("重新加载")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(AppTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("暂无每日推荐")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("多听几首歌培养口味，每天 6:00 更新")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            tracks = try await NeteaseMusicAPI.shared.dailyRecommendSongs()
        } catch {
            errorMessage = "每日推荐加载失败，请重试"
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack { DailyRecommendView() }
}
