import SwiftUI

/// 精选页（歌单广场）：
/// 顶部分类胶囊横滑 + 双列歌单网格 + 下拉刷新。
///
/// 数据走网易云明文 `api/top/playlist`（按分类），
/// 「全部」分类兜底官方热推。代码按本项目架构原创实现。
///
/// ⚠️ 性能：不订阅 PlayerCore；封面一律走 `WellRemoteImage` 缩图档位。
struct PlaylistSquareView: View {
    /// 精选分类（网易云官方常用分类精简版；「全部」= 热推全集）
    static let categories = ["全部", "华语", "流行", "摇滚", "民谣", "电子", "说唱",
                             "古风", "轻音乐", "爵士", "欧美", "日语", "韩语", "影视原声"]

    @State private var category: String = "全部"
    @State private var playlists: [WellPlaylistSummary] = []
    @State private var isLoading = true
    @State private var failed = false
    /// 加载去重：category 变化触发 task 与 initial task 重复拉取时直接跳过
    @State private var loadedKey = ""

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top),
    ]

    var body: some View {
        // ⚠️ 不带 NavigationStack：导航容器由 MainTabView 的 page() 统一提供（11:10 架构）。
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                categoryBar

                if failed && playlists.isEmpty {
                    retryState
                } else if isLoading && playlists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(playlists) { pl in
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
                        }
                    }
                    .padding(.horizontal, WellSearchMetrics.contentInset)
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

    // MARK: 加载

    private func load(force: Bool = false) async {
        let key = category
        guard force || key != loadedKey else { return }
        loadedKey = key
        isLoading = true
        failed = false
        do {
            var list: [WellPlaylistSummary] = []
            if key == "全部" {
                // 「全部」用个性化推荐兜底，比 top/playlist 的全集质量更高；
                // 个性化失败（未登录等）再退回 top/playlist 全集
                list = (try? await NeteaseMusicAPI.shared.personalizedPlaylists(limit: 40)) ?? []
                if list.isEmpty {
                    list = (try? await NeteaseMusicAPI.shared.categoryPlaylists(cat: "全部", limit: 40)) ?? []
                }
            } else {
                // 分类歌单（明文 api/playlist/list）；失败退个性化推荐，避免整页报错
                list = (try? await NeteaseMusicAPI.shared.categoryPlaylists(cat: key, limit: 40)) ?? []
                if list.isEmpty {
                    list = (try? await NeteaseMusicAPI.shared.personalizedPlaylists(limit: 40)) ?? []
                }
            }
            // 请求期间用户已切到别的分类 → 丢弃本次结果
            guard key == category else { return }
            playlists = list
            if list.isEmpty { failed = true }
        } catch {
            if key == category { failed = true }
        }
        isLoading = false
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
