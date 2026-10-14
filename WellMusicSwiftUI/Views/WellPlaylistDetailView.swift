import SwiftUI

/// 歌单 / 专辑 / 歌手详情页 —— 页面结构按 Apple Music 专辑页样式，代码按本项目重写。
///
/// 结构：大 header（封面96 + 名称 + 创建者/歌手 + 播放量）
/// → 播放全部 / 随机播放 双按钮
/// → 歌单内搜索框 + 排序菜单（默认 / 歌名 / 时长）
/// → 无分隔线歌曲列表（46 封面、行高 64）。
///
/// ⭐ 关键细节：**搜索与排序只改变可见列表，点击歌曲后的播放队列
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

    /// 歌单内排序方式
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
    /// 语义：搜索只影响可见列表，点歌后的队列顺序仍是排序后的完整顺序。
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
        // ⚠️ iOS 26 Apple Music 专辑/歌单页样式（用户指定一比一，实机对照截图定稿）：
        // 糊化封面垫满整页 + 全宽大封面（下段溶解进背景）→ 居中标题块
        // → shuffle/播放/收藏 三钮 → 搜索行 → 无分隔线歌曲列表。
        ZStack(alignment: .top) {
            backdropLayer

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

    // MARK: - 背景（Apple Music 同款「封面下段溶解」结构）
    //
    // 2026-10-14 用户放大对照实拍指出：Apple Music 的模糊**不是**在封面底边
    // 之下另起一块，而是封面**下半段就渐渐化开**、越往下越糊，封面本体溶解进
    // 模糊里（过渡浑然一体）。为此背景由两块拼接而成：
    //
    //   ① 与封面**同框同位**的糊化副本（溶解区的「底」——内容与封面逐像素对齐，
    //      封面底段渐隐时露出的是同一张图的同一位置，不会错位/重影）；
    //   ② 封面**底部带的镜像下延**（翻转后纵向拉伸），把封面之下的屏幕空间填满，
    //      接缝处两边都是图的第 100% 行、内容完全连续，模糊后不可分辨。
    //
    // 两块都固定（不随滚动），垫在最底（ZStack 第一层）。
    // ⚠️ 模糊层曾经历：系统白罩 0.55/0.30、「封面提取主色压层」——实机都被洗成
    //    灰调被用户否掉。现在**不压任何色层**，颜色完全由封面像素决定；
    //    saturation(1.25) 只用于抵消高斯模糊的去色效应。

    /// 封面在屏幕上的静止 y（滚动到顶时封面的顶边位置）。
    ///
    /// 由 `heroCover` 的背景 GeometryReader 测量，**只接受见过的最大值** ——
    /// 向下滚动时封面 y 变小、回到顶部时最大，所以最大值就是静止位置。
    /// 未测量出来前用 `backdropFallbackCoverTop` 兜底（首帧）。
    @State private var coverTopOnScreen: CGFloat = 0

    /// 测量未完成时的封面顶边估算（刘海屏：安全区 ≈59 + 导航栏 44）。
    private static let backdropFallbackCoverTop: CGFloat = 103
    /// 镜像下延取封面图底部多少比例（0.22 = 底部 22% 带翻转后纵向拉伸）。
    private static let backdropMirrorBand: CGFloat = 0.22
    /// 糊化层的高斯模糊半径与饱和度补偿（见上方结构说明）。
    private static let backdropBlurRadius: CGFloat = 55
    private static let backdropSaturation: Double = 1.25

    /// 固定背景层：① 同框糊化副本 + ② 底带镜像下延。
    private var backdropLayer: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let coverHeight = width   // 大封面是等宽方图
            let coverTop = coverTopOnScreen > 0 ? coverTopOnScreen : Self.backdropFallbackCoverTop
            let remaining = max(0, geo.size.height - coverTop - coverHeight)
            let mirrorScale = remaining > 0
                ? remaining / (Self.backdropMirrorBand * coverHeight)
                : 0
            ZStack(alignment: .top) {
                // ① 与封面同框同位的糊化副本 —— 封面下段渐隐时露出的「底」
                WellRemoteImage(url: headerCoverURL, displaySize: 720)
                    .frame(width: width, height: coverHeight)
                    .clipped()
                    .blur(radius: Self.backdropBlurRadius)
                    .saturation(Self.backdropSaturation)
                    .offset(y: coverTop)

                // ② 封面底部带的镜像下延 —— 填满封面之下到屏幕底部
                //    （offset 上移一整张 → 以图底边为轴翻转放大 → 顶部裁到所需高度；
                //     竖向拉伸把底部窄带铺满剩余空间，模糊后是平滑的色彩延续）
                WellRemoteImage(url: headerCoverURL, displaySize: 720)
                    .frame(width: width, height: coverHeight)
                    .clipped()
                    .offset(y: -coverHeight)
                    .scaleEffect(x: 1, y: -mirrorScale, anchor: .top)
                    .frame(width: width, height: remaining, alignment: .top)
                    .clipped()
                    .blur(radius: Self.backdropBlurRadius)
                    .saturation(Self.backdropSaturation)
                    .offset(y: coverTop + coverHeight)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - 全宽大封面

    /// 全宽方图封面；**下段渐隐**（约下半段起 → 底边）溶解进背后的糊化副本 ——
    /// Apple Music 的关键观感：模糊从封面下半段就渐渐开始，而不是底边一刀切。
    private var heroCover: some View {
        WellRemoteImage(url: headerCoverURL, displaySize: 720)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.56),
                        .init(color: .clear, location: 0.96),
                    ],
                    startPoint: .top,
                    endPoint: .bottom)
            )
            .background(
                // 测量封面静止时的屏幕位置（给固定背景层的 ① 号糊化副本对齐用；
                // 只取最大值，滚动中的较小值会被 noteCoverTop 忽略）
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { noteCoverTop(proxy.frame(in: .global).minY) }
                        .onChange(of: proxy.frame(in: .global).minY) { noteCoverTop($0) }
                }
            )
    }

    private func noteCoverTop(_ y: CGFloat) {
        guard y.isFinite, y > coverTopOnScreen else { return }
        coverTopOnScreen = y
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

/// 详情页歌曲行（46 封面 + 歌名/歌手 + 右侧时长，行高 64，无分隔线）。
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
