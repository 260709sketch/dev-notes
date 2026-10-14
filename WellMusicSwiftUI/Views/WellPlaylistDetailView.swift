import SwiftUI
import UIKit

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
        // 封面主色纯色铺满整页 + 全宽大封面（下段溶解进主色底）→ 居中标题块
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
            // ★ 深色封面自动识别：封面偏暗时整页文字转白（用户 2026-10-14 要求）。
            //   只强制 content 的配色方案，不影响系统导航栏。
            .environment(\.colorScheme, coverIsDark == true ? .dark : systemScheme)
        }
        // 系统导航栏（2026-10-14 用户要求加回）：标题 + 返回键 + 左滑返回全部回归原生；
        // 曾经的「隐藏导航栏 + 悬浮磨砂返回钮 + SwipeBackEnabler 左滑桥」整套替换方案
        // 已全部移除（悬浮钮定位、手势恢复都不再需要）。
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

    // MARK: - 背景（封面主色纯色铺底 + 封面下段溶解）
    //
    // 2026-10-14 三轮实机对照 + 逐像素采样定稿（用户三次发图纠错）：
    // · **背景 = 封面提取的单一主色、纯色铺满全屏**（用户原话：「图二的模糊
    //   颜色是吸取封面的单一颜色来做的」；对参考实拍采样证实：背景从 62% 到
    //   97% 屏高是同一个颜色 (19,37,37) —— 完全纯色，无渐变无结构）。
    //   曾试过并被否掉的方案：整图模糊铺底 / 只糊封面底部条带 / 同框对齐副本
    //   + 镜像下延 / 系统白罩 / 「提取色压层」—— 纯色铺底才是正确结构。
    // · 「黑封面周围泛白」不再用模糊图层后**从根上消失**：纯色没有模糊毛边，
    //   不存在边缘半透明透出系统白的问题。
    // · 深色封面自动识别（提取色明度）→ 整页文字转白（见 body 的 environment）。

    /// 系统当前配色方案（注入兜底：封面不深时原样透传，不改变外观）。
    @Environment(\.colorScheme) private var systemScheme

    /// 封面是否偏深（自动识别；nil = 未取到色，按系统方案显示）。
    @State private var coverIsDark: Bool?
    /// 封面主色纯色铺底（取色完成前用系统底色兜底）。
    @State private var coverBackdropColor: Color?

    /// 背景层：封面主色纯色铺满全屏（垫在最底、不随滚动）。
    private var backdropLayer: some View {
        (coverBackdropColor ?? Color(uiColor: .systemBackground))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: - 全宽大封面

    /// 全宽方图封面：主体全清晰，**底部约 15% 做递进模糊**自然融进主色底。
    ///
    /// 2026-10-14 用户指定参考「AMLL 的递进模糊」（实地核查 AMLL 源码：歌词行做
    /// 逐行 CSS blur —— 未唱的行 5px、已唱的行随距离递增、当前行 0，拖动时全关），
    /// 比「整段渐隐成纯色」自然。SwiftUI 无原生「空间渐变模糊」，这里用
    /// **多档模糊带叠层**实现等价效果：同图复制 4 份、各自不同 radius、
    /// 用交叠窗口的渐变遮罩只露出自己那一段 —— 自浅到深连续过渡。
    private var heroCover: some View {
        ZStack(alignment: .top) {
            // ① 清晰主体（顶部 6% 渐入防上推硬边；约 80% 后交给模糊带）
            coverImage
                .mask(coverMask([
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.80),
                    .init(color: .clear, location: 0.90),
                ]))
            // ② 递进模糊带（半径 5 → 28，窗口交叠 → 连续无台阶）
            coverImage.blur(radius: 5).mask(coverMask([
                .init(color: .clear, location: 0.78),
                .init(color: .black, location: 0.84),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 0.93),
            ]))
            coverImage.blur(radius: 10).mask(coverMask([
                .init(color: .clear, location: 0.85),
                .init(color: .black, location: 0.90),
                .init(color: .black, location: 0.93),
                .init(color: .clear, location: 0.965),
            ]))
            coverImage.blur(radius: 18).mask(coverMask([
                .init(color: .clear, location: 0.90),
                .init(color: .black, location: 0.945),
                .init(color: .black, location: 0.965),
                .init(color: .clear, location: 0.99),
            ]))
            coverImage.blur(radius: 28).mask(coverMask([
                .init(color: .clear, location: 0.95),
                .init(color: .black, location: 0.98),
                .init(color: .black, location: 1.0),
            ]))
        }
    }

    /// 封面图本体（各模糊带共用同一份缓存图，只多付 4 次静态模糊的 GPU 代价）。
    private var coverImage: some View {
        WellRemoteImage(url: headerCoverURL, displaySize: 720)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipped()
    }

    private func coverMask(_ stops: [Gradient.Stop]) -> LinearGradient {
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
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

        // 封面主色 → 纯色铺底 + 深色封面识别（整页文字转白）
        // 放在这里而不是 .task 里：每日推荐模式的封面是首曲封面，要等 tracks 到手。
        if coverBackdropColor == nil {
            await extractCoverBackdrop()
        }

        // 歌单简介（网易云歌单；每日推荐无）
        if case .playlist(let pid, let plat, _) = source, plat == .netease, !dailyMode {
            playlistDescription = await NeteaseMusicAPI.shared.playlistDescription(id: pid)
        }
    }

    /// 取封面主色（`dominantColor()`，32×32 平均色）作为纯色背景。
    ///
    /// 走 `WellImageCache` 的 **64pt 小图请求**（192px 档，与货架缩图共用缓存），
    /// 不为取色单独拉大图。两步调色（2026-10-14 按参考实拍标定）：
    /// 1. 提饱和度 ×1.25（32×32 平均色容易发灰）；
    /// 2. **明度自适应**：亮色往白掺 35%、暗色往黑掺 45% —— 贴参考实拍
    ///    （图三《Lover》浅粉底 (231,218,228)；图二绿封面深绿底），
    ///    同时天然保证正文与底色的对比度。取不到封面时保持 nil、回落系统底色。
    private func extractCoverBackdrop() async {
        guard let raw = headerCoverURL, !raw.isEmpty else { return }
        guard let url = WellArtworkURL.resolved(raw, pixelSize: WellArtworkURL.pixelSize(forPoints: 64)) else { return }
        guard let image = await WellImageCache.shared.image(for: url) else { return }
        let boosted = Self.saturated(image.dominantColor(), factor: 1.25)
        let adjusted = Self.lightnessAdjusted(boosted)
        withAnimation(.easeInOut(duration: 0.25)) {
            coverBackdropColor = Color(uiColor: adjusted)
        }
        coverIsDark = Self.luminance(of: adjusted) < 0.5
    }

    /// 提饱和度（HSB 途径；失败时原样返回）。
    private static func saturated(_ color: UIColor, factor: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        return UIColor(hue: h, saturation: min(s * factor, 1), brightness: b, alpha: 1)
    }

    /// 明度自适应（2026-10-14 第二轮实拍标定）：
    /// * 平均明度 > 0.62 → 亮封面：往白掺 35%（对齐《Lover》浅粉底 (231,218,228)）；
    /// * 其余一律**压暗到 42%**（对齐参考实拍：绿封面 0.375→0.15 = ×0.40、
    ///   Whole Lotta Red 黑白封面 0.53→0.22 深炭灰、深色人像 0.28→0.12 近黑）。
    ///   ⚠️ 早期「0.40~0.62 原样」的中间区间会把黑白封面渲染成灰底 —— 深色
    ///   封面渐隐进灰底非常难看（用户 2026-10-14 截图反馈），故取消该区间。
    private static func lightnessAdjusted(_ color: UIColor) -> UIColor {
        let lum = luminance(of: color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        if lum > 0.62 {
            let t: CGFloat = 0.35
            return UIColor(red: r + (1 - r) * t, green: g + (1 - g) * t, blue: b + (1 - b) * t, alpha: 1)
        }
        let scale: CGFloat = 0.42
        return UIColor(red: r * scale, green: g * scale, blue: b * scale, alpha: 1)
    }

    /// Rec.709 相对明度（取不到分量时按亮色处理）。
    ///
    /// ⚠️ UIColor 的分量解构 API 参数标签是必需的（`getRed(_:green:blue:alpha:)`）。
    private static func luminance(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 1 }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
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
