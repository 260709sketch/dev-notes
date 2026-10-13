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

    // MARK: - 排序 / 搜索（`orderedTracks` 是播放队列，`displayedTracks` 只是滤镜）

    /// 排序后的**完整队列**：播放 / 随机播放都按它走。
    ///
    /// Beans 同款语义：搜索只影响可见列表，点歌后的队列顺序仍是排序后的完整顺序。
    private var orderedTracks: [MusicItem] {
        switch sortMode {
        case .original:
            return tracks
        case .name:
            return tracks.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .duration:
            return tracks.sorted { $0.duration < $1.duration }
        }
    }

    /// 搜索过滤后的**可见列表**（只影响显示，不影响播放队列）。
    private var displayedTracks: [MusicItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return orderedTracks }
        return orderedTracks.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || ($0.artist ?? "").localizedCaseInsensitiveContains(keyword)
        }
    }

    /// 可见列表里的某一首对应完整队列的下标（点歌按队列顺序播）。
    private func playbackIndex(for item: MusicItem) -> Int {
        orderedTracks.firstIndex(where: { $0.id == item.id }) ?? 0
    }

    /// 加载失败的重试态。
    private var retryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("加载失败")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await load() }
            } label: {
                Text("重新加载")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        // ⚠️ iOS 26 Apple Music 专辑/歌单页样式（用户指定一比一）：
        // 封面主色模糊渐变铺满整页 + 全宽大封面 → 居中标题块 → shuffle/播放/收藏 三钮
        // → 搜索行 → 无分隔线歌曲列表。
        ZStack(alignment: .top) {
            // ★ 封面高斯模糊背景（Apple Music「每日推荐」同款融底效果）：
            //   同一张封面铺满**全屏** + 大半径高斯模糊，渐隐从**大封面下缘**
            //   开始、屏高 80% 前收到底色 —— dock / mini player 落在纯色上。
            //   ⚠️ 旧版图层只有 1.9 倍屏宽高，会在底栏上方戛然截止，
            //   截图表现为「dock 周围一块模糊断带」（2026-10-14 用户反馈）。
            //   模糊层垫在最底（ZStack 第一层），固定不随滚动（滚动跟随需要
            //   scrollClipDisabled，性能铁律禁用）。
            GeometryReader { geo in
                WellRemoteImage(url: headerCoverURL, displaySize: 720)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 80)
                    .overlay(
                        LinearGradient(
                            stops: backdropStops(width: geo.size.width, height: geo.size.height),
                            startPoint: .top,
                            endPoint: .bottom)
                    )
            }
            .ignoresSafeArea()
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

    /// 背景渐隐断点：大封面是全宽**方图**，下缘在 y = 屏宽处（占屏高 width/height）。
    ///
    /// * `clear` 保持到封面下缘 —— 封面上方区域被封面本身盖住（滚动时才露出），
    ///   下缘处模糊 artwork 与封面同源同位置，只有清晰度突变，颜色连续；
    /// * 之后经 ~45% 底纹过渡，**屏高 80% 前收到纯底色** —— dock / mini player
    ///   区域落在纯色上，不会再出现「模糊层在底栏上方截止」的断带；
    /// * 小屏（封面占屏高比例大）时自动夹取，保证渐隐区间不塌缩。
    private func backdropStops(width: CGFloat, height: CGFloat) -> [Gradient.Stop] {
        let edge = height > 0 ? min(max(width / height, 0.25), 0.6) : 0.45
        let fadeEnd = min(edge + 0.34, 0.80)
        let mid = edge + (fadeEnd - edge) * 0.45
        return [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: edge),
            .init(color: bgFadeColor.opacity(0.45), location: mid),
            .init(color: bgFadeColor, location: fadeEnd),
        ]
    }

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
        // ⚠️ 必须包一层 VStack：普通计算属性（非 `body`）不享受隐式返回，
        //    「HStack 行 + Divider」两条语句直接平铺会报
        //    "opaque return type ... no return statements"。
        VStack(spacing: 0) {
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
