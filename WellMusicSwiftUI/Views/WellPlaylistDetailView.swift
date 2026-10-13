import SwiftUI

/// 歌单 / 专辑 / 歌手详情页 —— 对齐 Beans `PlaylistView` 的页面结构，代码按本项目重写。
///
/// 结构：大 header（封面96 + 名称 + 创建者/歌手 + 播放量）
/// → 播放全部 / 随机播放 双按钮
/// → 歌单内搜索框 + 排序菜单（默认 / 歌名 / 时长）
/// → 无分隔线歌曲列表（46 封面、行高 64）。
///
/// ⭐ Beans 同款细节：**搜索与排序只改变可见列表，点击歌曲后的播放队列
/// 仍按排序后的完整顺序走**（`orderedTracks` 是队列，`displayedTracks` 只是滤镜）。
struct WellPlaylistDetailView: View {
    let source: WellSearchDetailSource
    var coverURL: String?
    /// 创建者名（歌单页显示；专辑/歌手页传空）
    var creatorName: String?
    /// 播放量（歌单页显示）
    var playCount: Int = 0
    /// ★ 每日推荐模式：数据走 `dailyRecommendSongs()`，header 封面用首曲封面
    var dailyMode: Bool = false

    @EnvironmentObject private var appState: AppState

    /// 歌单内排序方式（Beans 同款）
    enum SortMode: String, CaseIterable, Identifiable {
        case original = "默认"
        case name = "歌名"
        case duration = "时长"
        var id: String { rawValue }
    }

    @State private var tracks: [MusicItem] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var searchText = ""
    @State private var sortMode: SortMode = .original
    /// 歌单简介（Apple Music 样式：两行截断 + 「更多」展开）
    @State private var playlistDescription: String?
    @State private var showFullDescription = false

    /// 每日推荐模式下的 header 封面（首曲封面）
    private var headerCoverURL: String? {
        dailyMode ? (tracks.first?.albumCoverURL ?? coverURL) : coverURL
    }

    var body: some View {
        // ⚠️ iOS 26 Apple Music 专辑/歌单页样式（用户指定一比一）：
        // 封面主色模糊渐变铺满整页 + 全宽大封面 → 居中标题块 → shuffle/播放/收藏 三钮
        // → 搜索行 → 无分隔线歌曲列表。
        ZStack(alignment: .top) {
            // ★ 封面模糊延伸背景：同一张封面拉满全屏 + 大半径模糊，
            //   从封面下缘开始渐变过渡到系统背景色 —— Apple Music 标志性效果。
            //   固定不随滚动（滚动跟随需要 scrollClipDisabled，性能铁律禁用）。
            GeometryReader { geo in
                WellRemoteImage(url: headerCoverURL, displaySize: 720)
                    .frame(width: geo.size.width, height: geo.size.width * 1.9)
                    .clipped()
                    .blur(radius: 55)
                    .overlay(
                        LinearGradient(colors: [.clear, bgFadeColor.opacity(0.55), bgFadeColor],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    heroCover
                    titleBlock
                    controlsRow
                    descriptionBlock
                    searchRow
                    songsSection
                    Color.clear.frame(height: 170)
                }
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && tracks.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed && tracks.isEmpty {
                retryState
            }
        }
        .task {
            guard tracks.isEmpty else { return }
            await load()
        }
    }

    /// 模糊背景向下渐变的目标色（跟随系统深浅色）
    private var bgFadeColor: Color { Color(uiColor: .systemBackground) }

    // MARK: - 全宽大封面

    private var heroCover: some View {
        WellRemoteImage(url: headerCoverURL, displaySize: 720)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipped()
    }

    // MARK: - 居中标题块（Apple Music 同款：名 / 歌手 / 数量）

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(source.title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 20)
            if let creatorName, !creatorName.isEmpty {
                Text(creatorName)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            Text("\(tracks.count) 首")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    // MARK: - 控制行：shuffle 圆钮 / 白色播放胶囊 / 收藏圆钮

    private var controlsRow: some View {
        HStack(spacing: 12) {
            // 随机播放（圆形）
            Button {
                guard !orderedTracks.isEmpty else { return }
                PlayerCore.shared.play(queue: orderedTracks,
                                       startIndex: Int.random(in: 0..<orderedTracks.count))
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(orderedTracks.isEmpty)

            // 播放（白色大胶囊，黑字）
            Button {
                guard !orderedTracks.isEmpty else { return }
                PlayerCore.shared.play(queue: orderedTracks, startIndex: 0)
            } label: {
                Label("播放", systemImage: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(orderedTracks.isEmpty)

            // 收藏到本地歌单（圆形）
            Button {
                saveToLocalPlaylist()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - 简介（两行截断 + 「更多」展开，Apple Music 同款）

    @ViewBuilder
    private var descriptionBlock: some View {
        if let desc = playlistDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFullDescription.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(desc.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(showFullDescription ? nil : 2)
                            .multilineTextAlignment(.leading)
                        if !showFullDescription {
                            Text("更多")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    // MARK: - 搜索行（透明一行：放大镜 + 占位 + 排序「…」，Apple Music 同款无底色）

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                TextField("搜索歌单内歌曲", text: $searchText)
                    .font(.system(size: 14))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)

            // 排序菜单（…）
            Menu {
                Picker("排序", selection: $sortMode) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        Divider().padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    // MARK: - 歌曲列表（Apple Music 行：44 封面 + 名/歌手 + 右时长，无分隔线）

    @ViewBuilder
    private var songsSection: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if displayedTracks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text(searchText.isEmpty ? "暂无歌曲" : "没有匹配的歌曲")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, item in
                    Button {
                        PlayerCore.shared.play(queue: orderedTracks,
                                               startIndex: playbackIndex(for: item))
                    } label: {
                        appleMusicSongRow(index: index, item: item)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func appleMusicSongRow(index: Int, item: MusicItem) -> some View {
        HStack(spacing: 12) {
            WellRemoteImage(url: item.albumCoverURL, displaySize: 44)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.artist ?? "未知歌手")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.durationText)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// 收藏到本地歌单（与「我的歌单」共用存储）
    private func saveToLocalPlaylist() {
        let name = source.title
        guard !appState.playlists.contains(where: { $0.name == name && $0.tracks.count == tracks.count }) else {
            ToastCenter.shared.show("已收藏过该内容")
            return
        }
        appState.playlists.insert(Playlist(name: name, coverURL: headerCoverURL, tracks: tracks), at: 0)
        ToastCenter.shared.show("已收藏「\(name)」")
    }

    private func load() async {
        isLoading = true
        failed = false
        let fetched: [MusicItem]
        if dailyMode {
            fetched = (try? await NeteaseMusicAPI.shared.dailyRecommendSongs()) ?? []
        } else {
            fetched = await SearchService.shared.detailTracks(for: source)
        }
        tracks = fetched
        failed = fetched.isEmpty
        isLoading = false

        // 歌单简介（网易云歌单；每日推荐无）
        if case .playlist(let pid, let plat, _) = source, plat == .netease, !dailyMode {
            playlistDescription = await NeteaseMusicAPI.shared.playlistDescription(id: pid)
        }
    }
}

// MARK: - 详情歌曲行

/// 详情页歌曲行（Beans 同款：46 封面 + 歌名/歌手 + 右侧时长，行高 64，无分隔线）。
struct WellDetailSongRow: View {
    let item: MusicItem

    var body: some View {
        HStack(spacing: 12) {
            WellRemoteImage(url: item.albumCoverURL, displaySize: 46)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.artist ?? "未知歌手")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.durationText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(height: 64)
        .contentShape(Rectangle())
    }
}

#Preview {
    NavigationStack {
        WellPlaylistDetailView(
            source: .playlist(id: "1", platform: .netease, name: "示例歌单"),
            coverURL: nil, creatorName: "创建者", playCount: 12345)
    }
}
