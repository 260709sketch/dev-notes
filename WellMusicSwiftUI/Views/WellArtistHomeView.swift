import SwiftUI

/// 歌手主页 —— 界面代码按本项目架构重写。
///
/// 结构：Header（72pt 圆形头像 + 名字 + 统计）
/// → 热门歌曲（序号前 3 高亮 / 40pt 封面 / 歌名 + 专辑名，播放全部按钮，页内搜索过滤）
/// → 专辑 / EP 与单曲 两个横滑货架（160pt 封面 + 名称 + 中文发行日期）。
///
/// 数据：`artistTopSongs`（热门歌曲，平台返回多少显示多少，不人为截断）
/// + `artistAlbums`（专辑，offset 翻页拉全量；类型中英混合需一并识别）。
/// 专辑点击 → 歌单页样式详情（WellPlaylistDetailView）。
struct WellArtistHomeView: View {
    let artistId: String
    let artistName: String
    var coverURL: String?
    /// ★★ 2026-10-14：歌手所属平台。原先本页**只查网易云**，从播放页点歌手名
    /// 跳进来（QQ / 酷狗歌）必然全空 —— 见 `load()` 里的根因说明。
    var platform: MusicSource = .netease
    /// 平台歌手 mid（QQ / 酷狗的歌手接口需要）。调用方已知就直接传，
    /// 省掉进页后「按歌手名再搜一次解析身份」的网络往返（2026-10-15 提速）。
    var artistMid: String? = nil

    @State private var resolvedName: String = ""
    @State private var resolvedCover: String?
    @State private var hotSongs: [MusicItem] = []
    @State private var albums: [WellAlbumSummary] = []
    /// 平台侧专辑总数（`artist.albumSize`，如周杰伦 = 44）。
    /// 头部统计行优先显示它；接口没给时回落到 `albums.count`。
    @State private var platformAlbumCount: Int?
    @State private var isLoading = true
    @State private var failed = false
    @State private var searchText = ""
    // ★ 2026-10-17 歌手页重构（Kumone 风格）：简介 / 收藏态 / 相似歌手
    @State private var briefDesc = ""
    @Environment(\.colorScheme) private var colorScheme
    /// 歌手名字体：true = 衬线大字（默认），false = 系统字体
    @AppStorage("wellmusic.artist.serifTitle") private var serifTitle = true
    /// 下滑刷新：用户下滑超过阈值才后台重拉（不在打开时一起刷，避免变慢）
    @State private var didPullRefresh = false
    @State private var isFollowed = false
    @State private var similarArtists: [SimilarArtist] = []
    @State private var showingBio = false
    @State private var resolvedArtistId = ""
    /// ★ 2026-10-17 用户：模糊底色取**封面提取色**（Apple Music 同款）
    @State private var coverTint: Color = Color(.systemBackground)
    /// 提取色是否偏深（决定页面文字用白/黑，参考图深蓝底 → 白字）
    @State private var tintIsDark = false
    // MARK: - 主题色系统（2026-10-18 用户色域白名单）

    /// HSV
    private static func hsv(_ ui: UIColor) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        var h: CGFloat = 0, sa: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &sa, brightness: &v, alpha: &a)
        return (h * 360, sa, v)
    }

    /// 浅色模式允许提取的色相（度）：粉/蓝/浅蓝/绿/淡黄/褐，外加低饱和的浅灰米
    private static func lightAllowed(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> Bool {
        if s < 0.12 { return true }                      // 浅灰/米白
        if (320...360).contains(h) { return true }        // 粉/玫红
        if (190...260).contains(h) { return true }        // 蓝/浅蓝
        if (80...170).contains(h) { return true }         // 绿
        if (35...70).contains(h) { return true }          // 淡黄
        if (15...40).contains(h) { return true }          // 褐/橙
        return false
    }

    /// 深色模式允许提取的色相：深蓝/深绿等适合暗背景的（且本身够暗）
    private static func darkAllowed(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> Bool {
        guard v < 0.62 else { return false }
        if (200...255).contains(h) { return true }        // 深蓝
        if (90...175).contains(h) { return true }         // 深绿
        if (15...45).contains(h), v < 0.45 { return true } // 深褐
        return false
    }

    /// 背景色：命中色域 → 用提取色（深色模式压暗一档）；未命中 → 浅色白 / 深色黑
    private var backdropTint: Color {
        let ui = UIColor(coverTint)
        let (h, sv, v) = Self.hsv(ui)
        let isDark = colorScheme == .dark
        if isDark {
            guard Self.darkAllowed(h, sv, v) else { return Color(red: 0.07, green: 0.07, blue: 0.08) }
            let f: CGFloat = 0.22
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            return Color(red: Double(r * (1 - f)), green: Double(g * (1 - f)), blue: Double(b * (1 - f)))
        }
        guard Self.lightAllowed(h, sv, v) else { return Color(red: 0.99, green: 0.99, blue: 0.99) }
        return coverTint
    }

    /// 背景是否偏深（决定文字/图标黑白）
    private var backdropIsDark: Bool {
        let ui = UIColor(backdropTint)
        let (_, _, v) = Self.hsv(ui)
        return v < 0.55
    }

    /// 主题色：从背景提取色派生（不再固定黄/白）；白/黑底时回落系统蓝
    private var heroAccent: Color {
        let base = backdropTint
        let ui = UIColor(base)
        let (h, s, v) = Self.hsv(ui)
        // 白/黑底 → 系统蓝；有色底 → 提亮提饱和的派生色
        if s < 0.08 || (v > 0.93 && s < 0.2) { return Color.blue }
        return Color(hue: Double(h / 360), saturation: Double(min(1, s * 1.15 + 0.12)),
                     brightness: Double(min(1, v * (backdropIsDark ? 1.35 : 1.12))))
    }

    /// 名字颜色
    private var heroTitleColor: Color {
        backdropIsDark ? .white : Color.black.opacity(0.85)
    }

    /// 两侧按钮（ℹ️/☆）图标色
    private var heroGlyphColor: Color {
        backdropIsDark ? .white : Color.black.opacity(0.7)
    }


    struct SimilarArtist: Identifiable {
        let id: String
        let name: String
        let picURL: String?
    }
    /// ★ 2026-10-16 问题8：正在播放标识（低频订阅，见 NowPlayingTracker）
    @ObservedObject private var nowPlaying = NowPlayingTracker.shared

    /// 热门歌曲过滤（只影响显示，点击后的队列仍按完整顺序走）
    private var displayedHotSongs: [MusicItem] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return hotSongs }
        return hotSongs.filter { item in
            item.title.lowercased().contains(kw)
                || (item.artist ?? "").lowercased().contains(kw)
                || (item.album ?? "").lowercased().contains(kw)
        }
    }

    /// 热门歌曲总时长（mm:ss）
    private var hotSongsDurationText: String {
        let total = displayedHotSongs.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return "--:--" }
        let m = Int(total) / 60, sec = Int(total) % 60
        return String(format: "%d:%02d", m, sec)
    }

    private var studioAlbums: [WellAlbumSummary] { albums.filter { !$0.isEPOrSingle } }
    private var epsAndSingles: [WellAlbumSummary] { albums.filter(\.isEPOrSingle) }

    var body: some View {
        Group {
            if isLoading && hotSongs.isEmpty && albums.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed && hotSongs.isEmpty && albums.isEmpty {
                retryState
            } else {
                ZStack(alignment: .top) {
                    // ★ 2026-10-18 新版：背景 = 提取封面主色（与"居中留白"同款），
                    //   深色模式下压暗一档保证可读；无模糊层。
                    backdropTint.ignoresSafeArea().allowsHitTesting(false)

                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            artistHeader
                            latestReleaseCard
                            hotSongsSection
                            albumsSection
                            similarArtistSection
                            Color.clear.frame(height: 170)
                        }
                        .modifier(WellScrollOffsetReporter(space: "well-artist-scroll"))
                        .onPreferenceChange(WellScrollOffsetKey.self) { offset in
                            pullRefreshIfNeeded(offset: offset)
                        }
                        .id("well-page-top")
                        .padding(.top, 6)
                    }
                    .coordinateSpace(name: "well-artist-scroll")
                    // ★ 2026-10-16 问题24：上滑浮现「回到顶部」浮钮
                    .modifier(WellScrollToTopPageModifier(
                        space: "well-artist-scroll", topID: "well-page-top", proxy: proxy))
                    }
                }
            }
        }
        // ★ 2026-10-18 用户问题8：导航栏**不显示歌手名字**
        // ★ 2026-10-18 用户问题14：导航栏右侧 = 三个点（菜单）+ 分享歌手主页按钮
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // ★ 2026-10-18 用户问题5：分享在左、三个点在右，颜色统一蓝；
            //   三个点菜单去掉「收藏歌手」（页面已有收藏钮）。
            ToolbarItem(placement: .topBarTrailing) {
                Button { shareArtistPage() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.blue)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { shareArtistPage() } label: {
                        Label("分享歌手页", systemImage: "square.and.arrow.up")
                    }
                    Button { serifTitle.toggle() } label: {
                        Label(serifTitle ? "歌手名改用系统字体" : "歌手名改用衬线字体",
                              systemImage: "textformat")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.blue)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .sheet(isPresented: $showingBio) { bioSheet }
        // ★ 2026-10-14 用户：移除导航栏上的搜索框。
        //   原实现为 `.searchable(placement: .navigationBarDrawer(displayMode: .always))`
        //   —— 导航栏下方常驻一条「搜索歌手歌曲」，用户要求去掉。
        .task {
            guard hotSongs.isEmpty && albums.isEmpty else { return }
            await load(force: false)
        }
    }

    // MARK: - 分享 / 刷新

    /// 歌手主页分享链接（真实平台地址）
    private var artistShareURL: URL? {
        switch platform {
        case .qq:  return URL(string: "https://y.qq.com/n/ryqq/singer/\(resolvedArtistId)")
        case .kugou: return URL(string: "https://www.kugou.com/singer/\(resolvedArtistId)")
        default:   return URL(string: "https://music.163.com/#/artist?id=\(resolvedArtistId)")
        }
    }

    private func shareArtistPage() {
        guard let url = artistShareURL else { return }
        let name = resolvedName.isEmpty ? artistName : resolvedName
        let items: [Any] = ["\(name) - 歌手主页", url]
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        rootViewController()?.present(vc, animated: true)
    }

    private func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
    }

    /// 下滑刷新：用户下滑超过 140pt 才后台静默重拉（不在打开时刷，避免变慢）
    private func pullRefreshIfNeeded(offset: CGFloat) {
        guard !didPullRefresh, offset > 140 else { return }
        didPullRefresh = true
        Task { await load(force: true) }
    }

    // MARK: - Header

    private var artistHeader: some View {
        // ★ 2026-10-18 新版（用户 IMG_4077）：**圆形头像**在名字上方，
        //   直径 = 屏宽 × 0.46（比参考图那张唱片小一档）；名字与三钮样式保持现版。
        VStack(spacing: 12) {
            WellRemoteImage(url: resolvedCover ?? coverURL, displaySize: 480)
                .frame(width: UIScreen.main.bounds.width * 0.56,
                       height: UIScreen.main.bounds.width * 0.56)
                .clipShape(Circle())
                .background(Color.secondary.opacity(0.12), in: Circle())
                .drawingGroup()          // ★ 问题1：静态化，减少滚动时重合成
                .overlay {                // ★ 用描边替代投影（shadow 每帧重算，卡顿元凶之一）
                    Circle().stroke((backdropIsDark ? Color.white : Color.black).opacity(0.10),
                                    lineWidth: 1)
                }
                .padding(.top, 10)

            Text((resolvedName.isEmpty ? artistName : resolvedName).uppercased())
                .font(serifTitle
                      ? .system(size: 44, weight: .black, design: .serif)
                      : .system(size: 34, weight: .bold))
                .kerning(serifTitle ? -1 : 0)
                .minimumScaleFactor(0.6)
                .foregroundStyle(heroTitleColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HStack(spacing: 30) {
                Button { showingBio = true } label: {
                    Image(systemName: "info")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(heroGlyphColor)
                        .frame(width: 46, height: 46)
                        .background(tintIsDark ? Color.black.opacity(0.22)
                                               : Color.black.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(briefDesc.isEmpty ? 0.45 : 1)

                Button {
                    guard !displayedHotSongs.isEmpty else { return }
                    PlayerCore.shared.play(queue: displayedHotSongs, startIndex: 0)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 72, height: 72)
                        .background(backdropIsDark ? Color.white : Color.black.opacity(0.85),
                                    in: Circle())
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .opacity(displayedHotSongs.isEmpty ? 0.45 : 1)

                if platform == .netease {
                    Button {
                        let target = !isFollowed
                        isFollowed = target
                        Task {
                            guard !resolvedArtistId.isEmpty else { return }
                            try? await NeteaseMusicAPI.shared.setArtistSubscribed(
                                id: resolvedArtistId, subscribed: target)
                            ToastCenter.shared.show(target ? "已收藏歌手" : "已取消收藏歌手")
                        }
                    } label: {
                        Image(systemName: isFollowed ? "star.fill" : "star")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(heroGlyphColor)
                            .frame(width: 46, height: 46)
                            .background(tintIsDark ? Color.black.opacity(0.22)
                                                   : Color.black.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    /// 简介全文（底部弹窗）
    private var bioSheet: some View {
        NavigationStack {
            ScrollView {
                Text(briefDesc.isEmpty
                     ? (platform == .netease ? "暂无歌手简介" : "该平台暂未提供歌手简介")
                     : briefDesc)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("歌手简介")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingBio = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var hotSongsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ★ 2026-10-18 用户问题2/3/8：标题右侧改「总时长 + 正在播放指示器」，
            //   去掉三点；整行可长按弹出菜单（播放全部/加入队列）。
            HStack(spacing: 8) {
                Text("热门歌曲")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(backdropIsDark ? .white : Color.black.opacity(0.9))
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(backdropIsDark ? Color.white.opacity(0.7) : .secondary)
                Spacer(minLength: 8)
                if nowPlaying.isCurrent(displayedHotSongs.first ?? MusicItem(
                        source: .netease, platformId: nil, title: "", artist: nil,
                        album: nil, duration: 0, albumCoverURL: nil, neteaseId: nil,
                        qqSongMid: nil), at: 0) {
                    NowPlayingIndicator()
                }
                Text(hotSongsDurationText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(backdropIsDark ? Color.white.opacity(0.65)
                                                    : Color.black.opacity(0.45))
            }
            .padding(.horizontal, 16)
            .contextMenu {
                Button {
                    guard !displayedHotSongs.isEmpty else { return }
                    PlayerCore.shared.play(queue: displayedHotSongs, startIndex: 0)
                } label: { Label("播放全部", systemImage: "play.fill") }
                Button {
                    PlayerCore.shared.addToQueue(displayedHotSongs)
                } label: { Label("加入当前队列", systemImage: "text.badge.plus") }
            }

            if hotSongs.isEmpty {
                Text("暂无歌曲")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else if displayedHotSongs.isEmpty {
                Text("没有匹配的歌曲")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(displayedHotSongs.enumerated()), id: \.element.id) { index, item in
                        Button {
                            PlayerCore.shared.play(queue: displayedHotSongs, startIndex: index)
                        } label: {
                            hotSongRow(index: index, item: item,
                                       isCurrent: nowPlaying.isCurrent(item, at: index))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 热门歌曲行：`[封面40] 歌名 / 歌手名 …菜单`
    /// （歌曲行不显示 VIP 标识 —— 2026-10-14 用户要求；序号已按用户要求去除）
    private func hotSongRow(index: Int, item: MusicItem, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            WellRemoteImage(url: item.albumCoverURL, displaySize: 120)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    // ★ 2026-10-18 用户：深色模式文字不再变蓝 —— 颜色跟随底色，
                    //   "正在播放"由左侧音条动画（NowPlayingIndicator）区分。
                    .foregroundStyle(isCurrent ? heroAccent
                                            : (backdropIsDark ? Color.white : Color.black.opacity(0.9)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                // ★ 2026-10-17 用户：歌曲行副标题显示**歌手名**（原为专辑名）
                // ★ 2026-10-18 用户问题13：歌曲名下面显示**歌手名**（与平台一致）
                Text(item.artist ?? item.album ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(backdropIsDark ? Color.white.opacity(0.72)
                                                    : Color.black.opacity(0.55))
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            // ★ 2026-10-16 问题8：当前播放行显示音条动画
            if isCurrent {
                NowPlayingIndicator()
            } else {
                Spacer(minLength: 0)
            }

            // ★ 2026-10-17 截图同款：行尾 … 菜单
            Menu {
                Button {
                    PlayerCore.shared.play(queue: [item], startIndex: 0)
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                Button {
                    PlayerCore.shared.playNext(item)
                } label: {
                    Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(backdropIsDark ? Color.white.opacity(0.75)
                                                    : Color.black.opacity(0.45))
                    .frame(width: 44, height: 44)   // ★ 命中区加大，避免误触整行播放
                    .contentShape(Rectangle())
            }
        }
    }

    /// 从封面取主色（小图 64px 即可），供页面模糊背景着色
    private func resolveCoverTint() async {
        guard let raw = resolvedCover ?? coverURL, !raw.isEmpty,
              let url = WellArtworkURL.resolved(raw,
                                                pixelSize: WellArtworkURL.pixelSize(forPoints: 64)),
              let image = await WellImageCache.shared.image(for: url) else { return }
        let ui = image.dominantColor()
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        tintIsDark = lum < 0.62
        coverTint = Color(uiColor: ui)
    }

    // MARK: - 最新发行卡（Apple Music 截图同款；点击进专辑页）

    @ViewBuilder
    private var latestReleaseCard: some View {
        if let latest = albums.first {
            NavigationLink {
                WellPlaylistDetailView(
                    source: .album(id: latest.id, platform: latest.platform,
                                   name: latest.name, artist: latest.artistName,
                                   mid: latest.albumMid),
                    coverURL: latest.picURL,
                    creatorName: latest.artistName)
            } label: {
                HStack(spacing: 12) {
                    WellRemoteImage(url: latest.picURL, displaySize: 160)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        if let date = latest.publishDateText {
                            Text(date)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(backdropIsDark ? .white : .black)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Text(latest.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(latest.albumTypeText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .padding(10)
                // ★ 2026-10-18 用户：与 dock 栏同款**磨砂玻璃**
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .frame(height: 96)
        }
    }

    // MARK: - 相似歌手（Kumone 同款：圆头像横滑）

    @ViewBuilder
    private var similarArtistSection: some View {
        if !similarArtists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("相似歌手")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(backdropIsDark ? .white : Color.black.opacity(0.9))
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(similarArtists) { artist in
                            NavigationLink {
                                WellArtistHomeView(
                                    artistId: artist.id,
                                    artistName: artist.name,
                                    coverURL: artist.picURL,
                                    platform: platform)
                            } label: {
                                VStack(spacing: 8) {
                                    WellRemoteImage(url: artist.picURL, displaySize: 110)
                                        .frame(width: 110, height: 110)
                                        .clipShape(Circle())
                                        .background(Color.secondary.opacity(0.12), in: Circle())
                                    Text(artist.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(backdropIsDark ? .white
                                                                        : Color.black.opacity(0.85))
                                        .lineLimit(1)
                                        .frame(width: 110)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - 专辑（两个货架：专辑 / EP 与单曲）

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            albumShelf(title: "专辑", albums: studioAlbums)
            albumShelf(title: "EP 与单曲", albums: epsAndSingles)
        }
    }

    @ViewBuilder
    private func albumShelf(title: String, albums: [WellAlbumSummary]) -> some View {
        if !albums.isEmpty {
            WellShelf(title: title, rowHeight: 230) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                    NavigationLink {
                        WellPlaylistDetailView(
                            source: .album(id: album.id, platform: album.platform,
                                           name: album.name, artist: album.artistName,
                                           mid: album.albumMid),
                            coverURL: album.picURL,
                            creatorName: album.artistName)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            WellRemoteImage(url: album.picURL, displaySize: 160)
                                .frame(width: 160, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(album.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(width: 160, alignment: .leading)
                            // 发行日期中文化（「2025年6月5日」）；老数据没有
                            // publishTime 时回落类型文案（2026-10-14 用户要求）。
                            Text(album.publishDateText ?? album.albumTypeText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 160, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(WellCardEntrance(index: index, itemID: "artist-album-\(album.id)"))
                }
            }
        }
    }

    // MARK: - 状态与加载

    private var retryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("歌手信息加载失败")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 本页对应的搜索平台（QQ / 酷狗 / 网易云）；酷我等其他源没有独立歌手接口，返回 nil。
    private var searchPlatform: WellSearchPlatform? {
        switch platform {
        case .qq: return .qq
        case .kugou: return .kugou
        case .netease, .lx, .auto: return .netease
        default: return nil
        }
    }

    private func load(force: Bool = false) async {
        isLoading = true
        failed = false

        // ★★ 2026-10-14 用户：「播放器界面点击歌手名字转跳后，歌手主页没有头像、
        //    没有歌曲、没有专辑、没有 EP 与单曲」。
        //
        //    根因（`PlayerBridgeModels.Track.from(musicItem:)`）：
        //      * `ArtistRef.id` 是 **`keyOf.hashValue` 拼出来的假 id**，不是平台歌手 id；
        //      * `singerMid` 被填成了 **歌曲 mid**（`musicItem.qqSongMid`）。
        //    而本页原先只按「网易云歌手 id」查 → 拿到假 id 必然查空；头像也从来没带过来。
        //
        //    修法：进页先用「歌手名 + 平台」解析一次**真实身份**（id / mid / 头像），
        //    再按平台取热门歌曲与专辑。解析不到时才退回传进来的 id。
        let sp = searchPlatform
        var realId = artistId
        var realMid: String? = artistMid
        var resolvedAvatar: String?

        // ★ 2026-10-15 用户：「进入歌手主页要转圈那么久」——每次进页都要经历
        //   「解析身份 → 拉歌曲 + 专辑」至少 2~3 轮网络，全完成前整页转圈。
        //   加会话级快照缓存：再次进入立即渲染缓存，随后照常后台刷新（数据新鲜）。
        let cacheKey = artistId + "|" + artistName
        // ★ 2026-10-16 问题15：快照缓存改成**落盘**的歌手主页缓存 —— 冷启动再次进入
        //   同一歌手页也能先出内容；下面照常拉网络，拿到新内容覆盖缓存（图片由
        //   WellImageCache 自动落盘），所以发新专辑/换头像后依旧会进缓存。
        if let cached = await WellArtistHomeCache.shared.get(cacheKey) {
            realId = cached.artistId
            realMid = cached.artistMid
            resolvedAvatar = cached.avatar
            resolvedName = cached.name
            hotSongs = cached.songs
            albums = cached.albums
            platformAlbumCount = cached.albumCount
            isLoading = false
            // ★ 2026-10-18 用户问题9：打开时**只吃缓存**（秒开）；网络刷新留给
            //   用户下滑触发（pullRefreshIfNeeded → load(force: true)）。
            if !force { return }
        }

        // mid 缺失才按歌手名搜索解析身份（调用方已带 mid 时直接跳过，省一轮网络往返）
        if realMid == nil, let sp, !artistName.isEmpty {
            let found = await SearchService.shared
                .search(keyword: artistName, platform: sp, type: .artists, limit: 10).artists
            let exact = found.first { $0.name.caseInsensitiveCompare(artistName) == .orderedSame }
            if let match = exact ?? found.first {
                if !match.id.isEmpty { realId = match.id }
                realMid = match.mid
                resolvedAvatar = match.picURL
            }
        }

        // 热门歌曲与专辑**并行**拉取（原先串行 = 等待时间翻倍）
        async let songsTask = loadTopSongs(id: realId, mid: realMid)
        async let albumsTask = loadAlbums(id: realId, mid: realMid)
        let (songsResult, albumsResult) = await (songsTask, albumsTask)

        hotSongs = songsResult.songs
        albums = albumsResult.albums
        // ★ 2026-10-17 歌手页重构：简介 / 收藏态 / 相似歌手
        if let brief = songsResult.brief, !brief.isEmpty { briefDesc = brief }
        // ★ 2026-10-18 用户问题6：简介为空时补拉网易云歌手简介接口
        if briefDesc.isEmpty, platform == .netease, !realId.isEmpty {
            if let desc = try? await NeteaseMusicAPI.shared.artistDesc(id: realId),
               !desc.isEmpty { briefDesc = desc }
        }
        if let followed = songsResult.followed { isFollowed = followed }
        resolvedArtistId = realId
        if platform == .netease, !realId.isEmpty {
            let sims = (try? await NeteaseMusicAPI.shared.simiArtists(artistId: realId)) ?? []
            similarArtists = sims.map { SimilarArtist(id: $0.id, name: $0.name, picURL: $0.picURL) }
        }
        platformAlbumCount = albumsResult.count
        // ★ 封面提取色（模糊底色用）
        await resolveCoverTint()
        if resolvedName.isEmpty { resolvedName = artistName }
        if resolvedCover == nil {
            // ⚠️ 刻意**不写成一串 `??`**：`String? ?? String? ?? ...` 对 `??` 的两个重载
            //    都有解，表达式一长就会让类型检查器爆炸（本项目在 KugouMusicAPI 上
            //    踩过一次 `unable to type-check this expression in reasonable time`）。
            var candidate: String? = coverURL
            if candidate == nil { candidate = resolvedAvatar }
            if candidate == nil { candidate = songsResult.avatar }
            if candidate == nil { candidate = songsResult.songs.first?.albumCoverURL }
            resolvedCover = candidate
        }

        // 热门歌曲兜底：接口异常时用同名搜索补全（同样封顶 50 首）
        if hotSongs.isEmpty {
            let sp = searchPlatform ?? .netease
            hotSongs = await SearchService.shared
                .search(keyword: artistName, platform: sp, type: .songs, limit: 50).songs
        }

        failed = hotSongs.isEmpty && albums.isEmpty
        isLoading = false

        // 写入快照缓存（供下次进入秒开；失败态不缓存）
        // ★ 2026-10-17「间歇性 0 首」：旧条件允许「有专辑没歌曲」快照入库，
        //   风控瞬时失败被缓存放大 → 必须歌曲非空才缓存。
        if !failed, !hotSongs.isEmpty {
            await WellArtistHomeCache.shared.set(cacheKey, WellArtistHomeCache.Snapshot(
                artistId: realId,
                artistMid: realMid,
                name: resolvedName.isEmpty ? artistName : resolvedName,
                avatar: resolvedCover ?? resolvedAvatar,
                songs: hotSongs,
                albums: albums,
                albumCount: platformAlbumCount))
        }
    }

    /// 按平台取歌手热门歌曲；顺带带回平台给的歌手头像（酷狗 `singer/info` 有）。
    private func loadTopSongs(id: String, mid: String?)
        async -> (songs: [MusicItem], avatar: String?, brief: String?, followed: Bool?) {
        switch platform {
        case .qq:
            // QQ 歌手歌曲要的是 **singer mid**（不是歌曲 mid）
            let key = (mid?.isEmpty == false) ? (mid ?? id) : id
            if !key.isEmpty {
                // ★ 2026-10-17 全量：分页拉（50/页 × 最多 3 页），数量向平台靠拢
                var all: [MusicItem] = []
                var seen = Set<String>()
                for page in 0..<3 {
                    guard let result = try? await QQMusicAPI.shared.singerSongs(
                        singerMid: key, begin: page * 50, num: 50), !result.list.isEmpty else { break }
                    for item in result.list where seen.insert(item.keyOf).inserted { all.append(item) }
                    if !result.hasMore { break }
                }
                if !all.isEmpty { return (all, nil, nil, nil) }
            }
        case .kugou:
            if !id.isEmpty,
               let detail = try? await KugouMusicAPI.shared.singerDetail(singerId: id),
               !detail.songs.isEmpty {
                // ★ 2026-10-17 全量：再按分页补两页（30/页）
                var all = detail.songs
                var seen = Set(all.map { $0.keyOf })
                for page in 2...3 {
                    guard let more = try? await KugouMusicAPI.shared.singerSongs(
                        singerId: id, page: page, limit: 30), !more.list.isEmpty else { break }
                    for item in more.list where seen.insert(item.keyOf).inserted { all.append(item) }
                }
                return (all, detail.avatar, nil, nil)
            }
        default:
            if !id.isEmpty {
                // ★ 2026-10-17：一次拿「头像 + 热门歌曲」（weapi v1/artist 的 artist 对象），
                //   歌曲空时自动走 artist/songs(hot) 兜；仍空则 1.2s 重试一次。
                var profile = try? await NeteaseMusicAPI.shared.artistProfile(id: id)
                if profile?.hotSongs.isEmpty ?? true {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    profile = try? await NeteaseMusicAPI.shared.artistProfile(id: id)
                }
                if let profile, !profile.hotSongs.isEmpty {
                    return (profile.hotSongs, profile.avatarURL,
                            profile.briefDesc, profile.isFollowed)
                }
                // 歌曲仍空但拿到了头像 → 头像照用，歌曲交给外层搜索兜底
                if let profile, let avatar = profile.avatarURL {
                    return ([], avatar, profile.briefDesc, profile.isFollowed)
                }
            }
        }
        return ([], nil, nil, nil)
    }

    /// 按平台取歌手专辑。QQ 走 get_singer_album（需 mid）、酷狗走 v5 singer/album（需数字 id）；
    /// 网易云有真实接口（含平台总数）；失败回退「按歌手名搜专辑」。
    private func loadAlbums(id: String, mid: String?) async -> (albums: [WellAlbumSummary], count: Int?) {
        switch platform {
        case .qq:
            let key = (mid?.isEmpty == false) ? (mid ?? id) : id
            if !key.isEmpty,
               let result = try? await QQMusicAPI.shared.artistAlbums(singerMid: key, page: 1, limit: 50),
               !result.list.isEmpty {
                return (result.list, result.total)
            }
        case .kugou:
            if !id.isEmpty,
               let result = try? await KugouMusicAPI.shared.artistAlbums(singerId: id, page: 1, limit: 30),
               !result.list.isEmpty {
                return (result.list, result.total)
            }
        default:
            if !id.isEmpty,
               let result = try? await NeteaseMusicAPI.shared.artistAlbums(id: id),
               !result.albums.isEmpty {
                return (result.albums, result.platformAlbumCount)
            }
        }
        let sp = searchPlatform ?? .netease
        let found = await SearchService.shared
            .search(keyword: artistName, platform: sp, type: .albums, limit: 50).albums
        return (found, nil)
    }
}

#Preview {
    // 触发构建
    NavigationStack {
        WellArtistHomeView(artistId: "6452", artistName: "示例歌手")
    }
}

/// 歌手主页缓存：**落盘**保存「一次拉取到的歌手主页内容」。
///
/// 用户 2026-10-16 问题15：把没用的歌词缓存移除，换成**全新的歌手主页缓存** ——
/// 「用户第一次打开该歌手主页之后，里面的歌手头像、歌曲封面、专辑封面自动进入缓存；
/// 如果该歌手有最近更新（发新专辑 / 新歌、网易云换了头像），自动更新之后依旧进入缓存」。
///
/// 分两层落地：
/// * **图片**：头像 / 歌曲封面 / 专辑封面在展示时已由 `WellImageCache` 自动落盘
///   （磁盘副本，重启仍在），本类不重复存图，只保证「刷新出来的新封面一样会进缓存」
///   —— 新封面在页面上展示即入缓存，符合用户描述。
/// * **数据**：本类把歌手主页的数据存成 JSON（`Caches/artist-home/<md5>.json`），
///   冷启动再次进入同一歌手页先用缓存**立刻出内容**，随后照常后台重新拉取；
///   拉到新内容就覆盖缓存（新专辑/新头像随即被图片缓存接住）→ 数据变了才更新界面。
///
/// 容量：整体受「设置 → 存储 → 缓存上限」约束（`CacheBudget` 按最旧优先淘汰）。

actor WellArtistHomeCache {

    static let shared = WellArtistHomeCache()



    /// 缓存多久算「旧」（超过则在出缓存的同时后台重拉；现在是每次进入都会后台重拉，

    /// 这个值只用于存储页展示与「多久没被访问就淘汰」的判断）。

    static let staleAfter: TimeInterval = 6 * 60 * 60



    struct Snapshot: Codable {

        var artistId: String

        var artistMid: String?

        var name: String

        var avatar: String?

        var songs: [MusicItem]

        var albums: [WellAlbumSummary]

        var albumCount: Int?

        /// 写入时间（存储页展示「缓存于 …」用）

        var savedAt: Date = Date()

    }



    /// 内存层（同一会话内秒开，不用每次读盘）。

    private var memory: [String: Snapshot] = [:]

    private let maxMemoryEntries = 60



    private nonisolated(unsafe) let directory: URL



    private init() {

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

        directory = caches.appendingPathComponent("artist-home", isDirectory: true)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    }



    // MARK: 读写



    /// 取缓存（内存 → 磁盘）。读盘时顺手刷新文件时间，作为 LRU 的「最近使用」标记。

    func get(_ key: String) -> Snapshot? {

        if let hit = memory[key] { return hit }

        let url = fileURL(for: key)

        guard let data = try? Data(contentsOf: url),

              let snapshot = try? Self.decoder.decode(Snapshot.self, from: data) else { return nil }

        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)

        memory[key] = snapshot

        trimMemory()

        return snapshot

    }



    /// 写缓存（内存 + 磁盘）。

    func set(_ key: String, _ snapshot: Snapshot) {

        memory[key] = snapshot

        trimMemory()

        guard let data = try? Self.encoder.encode(snapshot) else { return }

        try? data.write(to: fileURL(for: key), options: .atomic)

        Task { @MainActor in CacheBudget.enforceIfNeeded() }

    }



    /// 清空歌手主页缓存（存储页用）。

    func clear() {

        memory.removeAll()

        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }

        for file in files { try? FileManager.default.removeItem(at: file) }

    }



    // MARK: 存储占用（存储页 / 总预算用）



    nonisolated func diskEntries() -> [CacheFileEntry] {

        guard let files = try? FileManager.default.contentsOfDirectory(

            at: directory,

            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }

        return files.compactMap { file in

            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }

            return CacheFileEntry(url: file,

                                  size: Int64(values.fileSize ?? 0),

                                  date: values.contentModificationDate ?? .distantPast,

                                  kind: .artist)

        }

    }



    nonisolated func diskUsage() -> Int64 {

        diskEntries().reduce(Int64(0)) { $0 + $1.size }

    }



    /// 缓存了多少位歌手（存储页展示用）。

    nonisolated func cachedCount() -> Int {

        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.count ?? 0

    }



    // MARK: 内部



    private func fileURL(for key: String) -> URL {

        directory.appendingPathComponent(Data(key.utf8).md5Hex() + ".json")

    }



    private func trimMemory() {

        guard memory.count > maxMemoryEntries else { return }

        for key in memory.keys.prefix(memory.count - maxMemoryEntries) {

            memory.removeValue(forKey: key)

        }

    }



    private static let encoder: JSONEncoder = {

        let encoder = JSONEncoder()

        encoder.dateEncodingStrategy = .iso8601

        return encoder

    }()



    private static let decoder: JSONDecoder = {

        let decoder = JSONDecoder()

        decoder.dateDecodingStrategy = .iso8601

        return decoder

    }()

}
