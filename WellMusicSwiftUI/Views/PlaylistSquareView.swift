import SwiftUI

/// 精选页（歌单广场）：
/// 顶部分类胶囊横滑 + 双列歌单网格（触底自动补齐）；「排行榜」分类展示排行榜网格。
///
/// 数据通道：
/// - 排行榜 → `api/toplist`
/// - 推荐歌单 → `api/personalized/playlist`
/// - 精品歌单 → `api/playlist/highquality/list`（lasttime 翻页）
/// - 其他分类 → `api/playlist/list`（offset 翻页，每页 50，上限 500）
///
/// ⚠️ 性能：不订阅 PlayerCore；封面一律走 `WellRemoteImage` 缩图档位。
struct PlaylistSquareView: View {
    /// 精选分类（「推荐歌单 / 精品歌单 / 排行榜」为特殊通道，其余走分类歌单接口）。
    static let categories = ["全部", "推荐歌单", "精品歌单", "排行榜", "官方",
                             "华语", "流行", "摇滚", "民谣", "电子", "轻音乐", "说唱", "爵士", "古典",
                             "影视原声", "ACG", "古风", "怀旧", "治愈", "放松", "伤感", "快乐",
                             "学习", "工作", "运动", "驾车", "夜晚"]

    @State private var category: String = "全部"
    @State private var playlists: [WellPlaylistSummary] = []
    @State private var toplists: [WellToplistSummary] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var failed = false
    /// 加载去重：category 变化触发 task 与 initial task 重复拉取时直接跳过
    @State private var loadedKey = ""
    /// `api/playlist/list` 的 offset（每页 50，上限 500）
    @State private var offset = 0
    /// 精品歌单的 lasttime
    @State private var highQualityBefore = 0
    @State private var hasMore = false

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top),
    ]

    var body: some View {
        // ⚠️ 不带 NavigationStack：导航容器由 MainTabView 的 page() 统一提供（11:10 架构）。
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                categoryBar

                if failed && playlists.isEmpty && toplists.isEmpty {
                    retryState
                } else if isLoading && playlists.isEmpty && toplists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else if category == "排行榜" {
                    toplistGrid
                } else {
                    playlistGrid
                }

                Color.clear.frame(height: 170)
            }
            .padding(.top, 8)
        }
        .navigationTitle("精选")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load(force: true) }
        .task(id: category) {
            await load()
        }
    }

    // MARK: 分类胶囊

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Color.clear.frame(width: WellSearchMetrics.contentInset - 8, height: 1)
                ForEach(Self.categories, id: \.self) { cat in
                    let selected = cat == category
                    Button {
                        guard !selected else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            category = cat
                        }
                    } label: {
                        Text(cat)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .white : Color.primary.opacity(0.75))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background {
                                Capsule().fill(selected ? AppTheme.accent : AppTheme.secondaryBackground)
                            }
                    }
                    .buttonStyle(.plain)
                }
                Color.clear.frame(width: WellSearchMetrics.contentInset - 8, height: 1)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 歌单网格（触底自动补齐）

    private var playlistGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(Array(playlists.enumerated()), id: \.element.id) { index, pl in
                NavigationLink {
                    WellPlaylistDetailView(
                        source: .playlist(id: pl.id, platform: .netease, name: pl.name),
                        coverURL: pl.coverURL,
                        creatorName: pl.creatorName,
                        playCount: pl.playCount)
                } label: {
                    WellCoverCard(coverURL: pl.coverURL, title: pl.name,
                                  subtitle: pl.creatorName,
                                  playCount: pl.playCount,
                                  fillWidth: true)
                }
                .buttonStyle(.plain)
                // 尾部 4 张卡片进入渲染窗口 → 自动拉下一页（LazyVGrid 的 cell 滚出即销毁，
                // 滚回会重新触发；列表中段卡片不会命中这个条件）
                .onAppear {
                    if index >= playlists.count - 4 {
                        Task { await loadMore() }
                    }
                }
            }
        }
        .padding(.horizontal, WellSearchMetrics.contentInset)
        .overlay(alignment: .bottom) {
            if isLoadingMore {
                ProgressView()
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .offset(y: 40)
            }
        }
    }

    // MARK: 排行榜网格

    private var toplistGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(toplists) { tl in
                NavigationLink {
                    WellPlaylistDetailView(
                        source: .playlist(id: tl.id, platform: .netease, name: tl.name),
                        coverURL: tl.coverURL,
                        creatorName: nil)
                } label: {
                    WellCoverCard(coverURL: tl.coverURL, title: tl.name,
                                  subtitle: tl.updateFrequency,
                                  fillWidth: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, WellSearchMetrics.contentInset)
    }

    // MARK: 加载

    private func load(force: Bool = false) async {
        let key = category
        guard force || key != loadedKey else { return }
        loadedKey = key
        isLoading = true
        failed = false
        playlists = []
        toplists = []
        offset = 0
        highQualityBefore = 0
        hasMore = false

        switch key {
        case "排行榜":
            toplists = (try? await NeteaseMusicAPI.shared.toplists()) ?? []
            if toplists.isEmpty { failed = true }
        case "推荐歌单":
            playlists = (try? await NeteaseMusicAPI.shared.personalizedPlaylists(limit: 100)) ?? []
            if playlists.isEmpty { failed = true }
        case "精品歌单":
            if let result = try? await NeteaseMusicAPI.shared.highQualityPlaylists(cat: "全部", limit: 50, before: 0) {
                playlists = result.playlists
                highQualityBefore = result.lasttime ?? 0
                hasMore = result.more && highQualityBefore > 0
            }
            if playlists.isEmpty { failed = true }
        default:
            // 分类歌单（明文 api/playlist/list）；失败退个性化推荐，避免整页报错
            playlists = (try? await NeteaseMusicAPI.shared.categoryPlaylists(cat: key, limit: 50, offset: 0)) ?? []
            if playlists.isEmpty {
                playlists = (try? await NeteaseMusicAPI.shared.personalizedPlaylists(limit: 50)) ?? []
            }
            offset = 50
            hasMore = !playlists.isEmpty
            if playlists.isEmpty { failed = true }
        }
        // 请求期间用户已切到别的分类 → 丢弃本次结果
        guard key == category else { return }
        isLoading = false
    }

    /// 触底加载下一页（按当前分类走各自通道）。
    private func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        let key = category
        isLoadingMore = true
        defer { isLoadingMore = false }

        switch key {
        case "精品歌单":
            if let result = try? await NeteaseMusicAPI.shared
                .highQualityPlaylists(cat: "全部", limit: 50, before: highQualityBefore) {
                guard key == category else { return }
                let existing = Set(playlists.map(\.id))
                playlists += result.playlists.filter { !existing.contains($0.id) }
                highQualityBefore = result.lasttime ?? 0
                hasMore = result.more && highQualityBefore > 0
            } else {
                hasMore = false
            }
        case "排行榜", "推荐歌单":
            hasMore = false
        default:
            let next = offset + 50
            if let list = try? await NeteaseMusicAPI.shared.categoryPlaylists(cat: key, limit: 50, offset: next),
               !list.isEmpty {
                guard key == category else { return }
                let existing = Set(playlists.map(\.id))
                playlists += list.filter { !existing.contains($0.id) }
                offset = next
                hasMore = next < 500
            } else {
                hasMore = false
            }
        }
    }

    private var retryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("歌单加载失败")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await load(force: true) }
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
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

#Preview {
    PlaylistSquareView()
}
