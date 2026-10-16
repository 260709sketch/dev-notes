import SwiftUI
import MediaPlayer
import UIKit

// Apple Music 风格全屏播放页（本项目自研实现）。
//
// 实现要点：
//   ✅ 竖屏大封面 → 歌词页的封面/文本锚点插值动画、横屏左右分栏布局、
//      迷你歌词预览、常驻音量条、歌词拖拽手势（含底部控制区联动隐藏）、
//      睡眠定时菜单、播放器样式 Sheet、整体视觉与动效参数。
//   ✅ 进度条时间源统一走 `PlayerCore.beginScrubbing/updateScrubbing/endScrubbing`。
//   ✅ AMLL 歌词同步统一走 `AMLLWebLyricsView` + `hardCalibrate` 通道。
//
// ⚠️ 性能红线：本页顶层**禁止**观察高频时钟（如 `PlayerCore.currentTime` 等 20Hz 源）。
//    它含有 WKWebView + WebGL 背景，任何 20Hz 的 `@Published` 都会导致整页全量重算，
//    表现为「一打开播放器就卡死」。时间只在叶子节点（进度条、歌词游标）内消费。

/// Apple Music 风格全屏播放页：封面模糊背景 + 大封面/歌词页切换 + 底部控制栏。
struct AppleMusicPlayerView: View {
    let onOpenDestination: (NowPlayingDestination) -> Void
    let onDismiss: () -> Void

    /// 底部安全区域间距（不用 GeometryReader，避免 fullScreenCover 动画过程中尺寸不正确）
    static var safeAreaBottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.bottom ?? 0
    }

    /// 顶部安全区域间距。下滑关闭的指示条要在灵动岛下方，不能用固定值。
    static var safeAreaTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.top ?? 0
    }

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    /// ⚠️ 本页**不再**直接观察 `\.colorScheme`：只有背景层需要区分深浅色，
    ///    它已经下沉到 `AppleMusicPlayerBackground` 自己的环境里。
    ///    留在这一层会让「主题切换」把整个播放页（含 WebView 歌词层）重算一遍。
    /// ⚠️ **不要**在这里 `@ObservedObject AccountStore.shared`。
    ///
    /// 收藏状态只影响「心形图标」这一个叶子节点。若在播放页顶层观察它，
    /// 任何一次收藏变化（以及历史上 `AccountStore` 里那个 0.5s 轮询定时器）
    /// 都会让**整页**全量重算 —— 包括 `UIScreen.main.bounds`、安全区遍历、
    /// 以及最贵的 `AMLLWebRepresentable.updateUIView`（往 474KB 的 WebGL
    /// 歌词页下发 JS）。这正是「打开播放器就卡死」的成因之一。
    ///
    /// 现在改为由叶子视图 `PlayerLikeButton` 自己订阅，重算范围收敛到按钮本身。
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared

    @State private var showLyrics = false
    @State private var headerDragOffset: CGFloat = 0
    @State private var showQueue = false
    @State private var showComments = false
    @State private var showAddToPlaylist = false
    @State private var showLyricOffsetSheet = false
    @State private var showPlaybackModeSheet = false
    @State private var showPlayerAdjustSheet = false
    @State private var showVolumePopover = false
    @State private var appleLayoutPart: AppleMusicLayoutPart = .cover
    /// 生效歌词偏移（秒）：调整过当前这首歌 = 该曲专属值；否则 = 全局值。
    /// 按曲记忆的写入与回落规则见 `AppState.effectiveLyricOffset` / `LyricOffsetSheet.apply`。
    private var lyricOffset: Double {
        player.effectiveLyricOffset
    }
    @AppStorage("wellmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage("wellmusic.player.swipeSwitchSong") private var swipeSwitchSong = true

    // MARK: 「播放器调整」里需要**实时预览**的项
    //
    // ⚠️ 这里必须用本视图自己的 `@AppStorage` 镜像，不能只读 `settings.xxx`。
    //
    // `SettingsManager` 上的 `@AppStorage` 写入时**不会**触发 `objectWillChange`，
    // 所以只观察 `settings` 的视图拿不到刷新 —— 在调整页面拖滑块时背景不会动。
    // `@AppStorage` 依赖 `UserDefaults` 的变更通知，两边用同一个 key 就会同步，
    // 因此在这里再声明一份即可拿到实时刷新（值本身仍存在同一处 UserDefaults）。
    @AppStorage("wellmusic.appleMusic.backgroundMode") private var bgMode: AppleMusicBackgroundMode = .dark
    @AppStorage("wellmusic.appleMusic.backgroundDim") private var bgDim: Double = 0.04
    @AppStorage("wellmusic.appleMusic.amllLyricTopPx") private var amllTopPx: Int = 140
    @AppStorage("wellmusic.appleMusic.amllLyricBottomPx") private var amllBottomPx: Int = 335
    @AppStorage("wellmusic.appleMusic.amllLyricHorizontalPx") private var amllHorizPx: Int = 0
    /// ★ 2026-10-16 用户问题11：歌词对齐（0 居中 / 1 左 / 2 右；默认居中）
    @AppStorage("wellmusic.appleMusic.lyricAlignment") private var lyricAlignment: Int = 0
    /// 歌名 / 歌手信息字号（需求 12；0 表示未设置，用默认值）
    @AppStorage("wellmusic.appleMusic.trackTitleFontSize") private var trackTitleFontSizeRaw: Double = 0
    @AppStorage("wellmusic.appleMusic.trackArtistFontSize") private var trackArtistFontSizeRaw: Double = 0

    /// 歌名字号（默认 22）
    private var trackTitleFontSize: CGFloat {
        trackTitleFontSizeRaw > 0 ? CGFloat(trackTitleFontSizeRaw) : 22
    }
    /// 歌手信息字号（默认 13.5）
    private var trackArtistFontSize: CGFloat {
        trackArtistFontSizeRaw > 0 ? CGFloat(trackArtistFontSizeRaw) : 13.5
    }

    /// 下滑关闭的驱动盒（引用类型，实例恒定）。
    ///
    /// 各个下滑热区把手势翻译成位移写进它，薄壳消费。⚠️ 位移状态**不在本视图上** ——
    /// 本视图只持有这个不参与 diff 的盒子，所以拖拽期间本页不会重算
    /// （本页含 WebView 歌词层，每次重算都要重新下发 JS）。详见 `PlayerDismissDragDriver`。
    @State private var dismissDriver = PlayerDismissDragDriver()

    /// 歌词行中线表。
    ///
    /// ⚠️ **刻意不用 `@State`**（2026-10-14 播放器性能排查）。
    ///
    /// 滚动歌词时 `LyricLineCenterKey` 这个偏好**每一帧**都会更新（每一行的
    /// `GeometryReader` 都随滚动重新上报）。把它写进 `@State` 会让 SwiftUI 认为
    /// 播放页整体失效 → 每一帧重算整棵树（封面插值层、控制栏、背景 representable…），
    /// 这就是「歌词页下滑掉帧 / 不跟手」的直接来源。
    ///
    /// 改成一个**不可观察**的引用盒：数据照收（拖拽时仍要用），但不触发任何视图失效。
    /// 真正需要驱动界面跟随的只有 `focusedLyricID`（当前高亮行），它只在**跨行**时才变。
    private final class LyricCenterBox {
        var value: [Int: CGFloat] = [:]
    }

    @State private var lyricCentersBox = LyricCenterBox()
    @State private var focusedLyricID: Int?
    @State private var lyricsViewportHeight: CGFloat = 0
    @State private var isDraggingLyrics = false
    @State private var hideBottomControls = false
    @State private var resumeTask: Task<Void, Never>?
    @StateObject private var dynamicCover = DynamicCoverManager()

    private var track: Track? { player.currentTrack }
    private var lyrics: [LyricLine] { player.lyrics?.lines ?? [] }
    private var coverURL: URL? {
        guard let pic = track?.album.picUrl else { return nil }
        return URL(string: pic)
    }

    private func layoutEntry(_ part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        appleLayout.entry(for: part)
    }

    var body: some View {
        // ★ 下滑关闭的跟手位移被关进一层**薄壳**（`PlayerDismissDragContainer`）。
        //
        // 原因：本页顶层含 `WKWebView`（WebGL 歌词层）。若把「拖动位移」写成
        // 本视图的 `@State`，拖拽期间每一帧都会让**整个播放页的 body 重算一次**，
        // 连带 `updateUIView` 也被每帧调用（重新下发 JS、重建触摸处理器）——
        // 表现就是「下滑不跟手、掉帧、歌词页下滑关闭很难受」。
        //
        // 薄壳只负责 `content.offset(y:)`，而 `content`（`playerCanvas`）是
        // **构造好的既有视图值**，拖拽期间不会被重新求值 —— 位移变化只重算
        // 薄壳自己的 body。这与系统原生播放器的手感一致。
        // ⚠️ 这里必须写成 `content:` 具名参数，**不能**用尾随闭包：
        //    `content` 是已求值的视图值（`Content`），不是 `() -> Content`
        //    闭包。写成尾随闭包会让编译器尝试把闭包本身当作 `Content`，
        //    报 `type '() -> some View' cannot conform to 'View'`。
        PlayerDismissDragContainer(
            driver: dismissDriver,
            onDismiss: onDismiss,
            isEnabled: !showLyrics,
            content: playerCanvas
        )
    }

    /// 播放页内容本体（不含下滑关闭的跟手位移，那部分在薄壳里）。
    ///
    /// ⚠️ 必须显式标 `@ViewBuilder`：它从 `body` 里拆出来之后就不再享有
    /// `View.body` 隐含的 `@ViewBuilder`，而这里开头有两个 `let` 再加一个
    /// `ZStack`，没有 ViewBuilder 会被判定为「没有 return 语句」而编译失败。
    @ViewBuilder
    private var playerCanvas: some View {
        // 不用 GeometryReader，避免 fullScreenCover 动画过程中尺寸不正确导致播放器只展开一半
        let screenSize = UIScreen.main.bounds.size
        let isLandscape = screenSize.width > screenSize.height

        ZStack {
            // ⚠️ 这里**不放任何固定底色**。
            //
            // 之前这里铺过「纯黑」和「随位移淡出的深色遮罩」两种方案，都被用户否掉：
            // 下滑关闭时总会看到**一整块黑/白的页面粘着播放器一起下滑**。
            //
            // 根因不在这一层，而在 `fullScreenCover` 的系统宿主视图：
            // 系统在播放页内容背后垫了一层**不透明背景**（浅色模式是白、深色是黑），
            // 我们自己拖 `.offset` 时这层宿主不会跟着走 → 露出白/黑板。
            //
            // 正解：用 `PresentedSurfaceClearer` 把整条宿主视图链刷成透明
            // （见文件末尾），让下层的 tab 页面直接透出来。这样下滑时看到的是
            // **真正的下层页面**，既没有白板也没有黑板，和系统原生转场一致。
            PresentedSurfaceClearer()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            ZStack {
                // 底层：playerBackground 内部已集成 AMLL（开启时）或原版背景
                playerBackground

                if isLandscape {
                    // 横屏布局：左右分栏，参考沉浸模式 regularLayout
                    landscapeLayout(size: screenSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 竖屏布局：原有布局
                    portraitLayout(size: screenSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 下滑关闭指示条：既是视觉提示，也是唯一的拖拽热区。
                //
                // ⚠️ 只在**大封面**状态出现。歌词页展开后要留给歌词自己的滚动/拖拽，
                // 而且那里顶部已经有自己的下滑手势（`headerDismissGesture`）。
                // 用户可在「播放器调整 → 顶部」里隐藏这条指示器（手势仍可用）。
                if !showLyrics && !isLandscape && !settings.appleMusicHideTopIndicator {
                    dismissIndicator
                        .padding(.top, Self.safeAreaTopInset + 1)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .zIndex(1)
                }
                // 隐藏指示条后，手势热区单独挂一层透明视图，保证仍能下滑关闭。
                if !showLyrics && !isLandscape && settings.appleMusicHideTopIndicator {
                    Color.clear
                        .frame(height: Self.dismissIndicatorHitHeight)
                        .frame(maxWidth: Self.dismissIndicatorHitWidth)
                        .contentShape(Rectangle())
                        .gesture(dismissDragGesture)
                        .padding(.top, Self.safeAreaTopInset + 1)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .zIndex(1)
                }
            }
            // ⚠️ 这里**不再**写 `.offset(y: 跟手位移)`：位移已上移到薄壳
            //    `PlayerDismissDragContainer`，避免它每帧让本页（含 WebView）重算。
            //    详见 `body` 里的说明。
        }
        .ignoresSafeArea()
        // 歌词页面可见时禁用播放器下滑关闭手势，避免和歌词滚动手势冲突
        .environment(\.allowsNowPlayingDismiss, !showLyrics)
        .onChange(of: showLyrics) { _ in
            // 切换回大封面时重置底部控制区域隐藏状态
            hideBottomControls = false
        }
        .onAppear {
            // 下滑关闭的位移状态改由薄壳 `PlayerDismissDragContainer` 自行复位
            // （`fullScreenCover` 的内容视图可能被复用，残留位移会让播放器
            //   打开时就偏移半屏）。
            if settings.dynamicCoverEnabled { dynamicCover.updateTrack(track) }
        }
        .onChange(of: track?.id) { _ in if settings.dynamicCoverEnabled { dynamicCover.updateTrack(track) } }
        .onChange(of: settings.dynamicCoverEnabled) { enabled in
            if enabled {
                dynamicCover.updateTrack(track)
            } else {
                dynamicCover.clear()
            }
        }
        .onDisappear { resumeTask?.cancel() }
        .sheet(isPresented: $showQueue) {
            Group {
                if #available(iOS 16.4, *) {
                    PlayQueueList()
                        .environmentObject(player)
                        .presentationDetents([.medium, .large])
                        .presentationBackground(.ultraThinMaterial)
                } else {
                    PlayQueueList()
                        .environmentObject(player)
                        .presentationDetents([.medium, .large])
                }
            }
        }
        .sheet(isPresented: $showComments) {
            Group {
                if let t = track {
                    CommentsView(track: t)
                }
            }
            .modifier(PlayerSheetDetents())
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let t = track {
                AddToPlaylistSheet(track: t)
            }
        }
        .sheet(isPresented: $showPlaybackModeSheet) {
            PlaybackModeSheet()
        }
        .sheet(isPresented: $showLyricOffsetSheet) {
            LyricOffsetSheet()
        }
        .sheet(isPresented: $showPlayerAdjustSheet) {
            PlayerAdjustSheet()
                .environmentObject(settings)
        }
    }

    // MARK: - 三点菜单

    @ViewBuilder
    private var moreMenu: some View {
        Menu {
            // 评论
            Button {
                showComments = true
            } label: {
                Label("评论", systemImage: "bubble.left")
            }

            // 查看专辑
            // ★ 2026-10-14 用户：「移除下一首播放，新增查看专辑」。
            //   跳转统一走 `onOpenDestination` → 由 MainTabView 关掉播放页并 push。
            if let t = track, let albumDestination = NowPlayingDestination.album(from: t) {
                Button {
                    onOpenDestination(albumDestination)
                } label: {
                    Label("查看专辑", systemImage: "square.stack")
                }
            }

            // 加入歌单
            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单…", systemImage: "music.note.list")
            }

            Divider()

            // 歌词偏移
            Button {
                showLyricOffsetSheet = true
            } label: {
                Label("歌词偏移", systemImage: "timer")
            }

            // 播放器调整：背景明暗/暗度 + AMLL 歌词位置/字体，集中在一个页面里
            Button {
                showPlayerAdjustSheet = true
            } label: {
                Label("播放器调整", systemImage: "slider.horizontal.3")
            }

            // 睡眠定时
            SleepTimerMenu(timer: player.sleepTimer, onCustom: { showCustomSleepTimerAlert() })

            // 分享歌曲（点击弹出系统分享，自带平台分享链接）
            if let link = trackShareLink {
                ShareLink(item: link) {
                    Label("分享歌曲", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            compactActionButton(icon: "ellipsis") {}
        }
    }

    /// 当前曲目的平台分享链接（分享入口用）。
    /// ⚠️ 平台判断走 `MusicSource.fromPlatformTag`（两套 tag 都认）；
    /// 用 `platformSongId`（平台侧真实 id）—— `t.id` 是本地稳定哈希，不能用。
    private var trackShareLink: String? {
        guard let t = track, let songId = t.platformSongId, !songId.isEmpty else { return nil }
        switch MusicSource.fromPlatformTag(t.sourcePlatform) {
        case .qq:
            return "https://y.qq.com/n/ryqq/songDetail/\(songId)"
        case .kugou:
            return "https://www.kugou.com/song/#hash=\(songId)"
        default:
            return "https://music.163.com/#/song?id=\(songId)"
        }
    }

    private var playbackModeText: String {
        if player.shuffleEnabled { return "随机播放" }
        switch player.repeatMode {
        case .one: return "单曲循环"
        case .all: return "列表循环"
        case .off: return "顺序播放"
        }
    }

    // MARK: - 竖屏布局

    private func portraitLayout(size: CGSize) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: PlayerLayoutMetrics.headerTopSpacing)

            ZStack {
                coverPage(size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showLyrics ? 0 : 1)
                    // ⚠️ 关键：`.opacity(0)` 的视图**依然接收点击**。不加这行，
                    // 未展开的歌词页会盖在封面页上吃掉所有点击（表现为「什么都点不了」）。
                    .allowsHitTesting(!showLyrics)
                    // ★ 大封面下滑关闭热区：整页可拖，不再只有顶部 180×82 小指示条
                    //   （「大封面状态下下滑很难触发」的根源）。与 Apple Music
                    //   全屏播放器「封面区域下滑即收起」一致。
                    // 默认 `.subviews` mask：封面内的点击（开歌词页 / 喜欢 / 更多 /
                    // 迷你歌词预览）仍由子视图优先，只有真正的拖拽才走关闭手势。
                    .contentShape(Rectangle())
                    .gesture(coverDismissGesture)
                lyricsPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showLyrics ? 1 : 0)
                    .allowsHitTesting(showLyrics)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 封面插值动画：在两个占位锚点之间移动同一个 CoverImage
            .overlayPreferenceValue(AppleMusicArtworkFrameKey.self) { artworkFrames in
                GeometryReader { proxy in
                    artworkTransitionLayer(frames: artworkFrames, proxy: proxy)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showLyrics)
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: player.isPlaying)

            playbackControls(bottomInset: Self.safeAreaBottomInset)
                .offset(y: (showLyrics && hideBottomControls) ? 260 : -20)
                .opacity((showLyrics && hideBottomControls) ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: hideBottomControls)
                .animation(.easeInOut(duration: 0.25), value: showLyrics)
        }
        .frame(width: size.width, height: size.height)
    }

    /// 封面在「大封面位」与「歌词页迷你位」之间插值的那一层。
    ///
    /// 单独成方法：整段写在 `portraitLayout` 里会让类型检查器推断过久。
    @ViewBuilder
    private func artworkTransitionLayer(
        frames: [CoverArtAnchor: Anchor<CGRect>],
        proxy: GeometryProxy
    ) -> some View {
        if let expanded = frames[.expanded], let compact = frames[.compact] {
            let targetFrame = showLyrics ? proxy[compact] : proxy[expanded]
            artworkLayerContent(targetFrame: targetFrame)
        }
    }

    /// 按给定落点绘制封面（静态图 + 可选动态封面视频）。
    private func artworkLayerContent(targetFrame: CGRect) -> some View {
        let cornerRadius: CGFloat = showLyrics ? 10 : 18
        let side = targetFrame.width
        // ★ 需求 11：大封面位置调整（仅大封面状态生效；歌词页迷你封面跟随占位锚点，不叠加偏移）
        let coverEntry = layoutEntry(.cover)
        let coverOffsetX = showLyrics ? 0 : coverEntry.x
        let coverOffsetY = showLyrics ? 0 : coverEntry.y

        return ZStack {
            // 封面图片始终作为底层
            CoverImage(
                url: coverURL,
                size: side,
                cornerRadius: cornerRadius,
                emptyHint: player.isBuffering ? "等待开始播放…" : nil
            )
            .frame(width: side, height: targetFrame.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // 动态封面视频叠加在上面
            if settings.dynamicCoverEnabled, let dynamicURL = dynamicCover.coverURL {
                DynamicCoverPlayer(url: dynamicURL, isMusicPaused: !player.isPlaying)
                    .frame(width: side, height: targetFrame.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .shadow(color: .black.opacity(showLyrics ? 0.26 : 0.46),
                radius: showLyrics ? 9 : 36,
                y: showLyrics ? 4 : 18)
        .scaleEffect(showLyrics ? 1 : (player.isPlaying ? 1 : 0.965) * coverEntry.scale)
        .position(x: targetFrame.midX + coverOffsetX, y: targetFrame.midY + coverOffsetY)
        .allowsHitTesting(false)
    }

    // MARK: - 横屏布局（参考沉浸模式 regularLayout，左右分栏）

    private func landscapeLayout(size: CGSize) -> some View {
        // 横屏时封面尺寸：参考沉浸模式的计算方式
        let artworkSize = max(ScreenAdapter.h(120),
                              min(ScreenAdapter.h(280), size.height * 0.55, size.width * 0.28))

        return HStack(spacing: 0) {
            // 左侧：封面 + 歌曲信息 + 进度条 + 控制按钮 + 底部按钮
            VStack(spacing: 0) {
                Spacer()

                // 封面
                ZStack {
                    CoverImage(
                        url: coverURL,
                        size: artworkSize,
                        cornerRadius: ScreenAdapter.h(16),
                        emptyHint: player.isBuffering ? "等待开始播放…" : nil
                    )
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: ScreenAdapter.h(16), style: .continuous))

                    // 动态封面视频叠加在上面
                    if settings.dynamicCoverEnabled, let dynamicURL = dynamicCover.coverURL {
                        DynamicCoverPlayer(url: dynamicURL, isMusicPaused: !player.isPlaying)
                            .frame(width: artworkSize, height: artworkSize)
                            .clipShape(RoundedRectangle(cornerRadius: ScreenAdapter.h(16), style: .continuous))
                    }
                }
                .shadow(color: .black.opacity(0.4), radius: ScreenAdapter.h(24), y: ScreenAdapter.h(12))
                .scaleEffect(player.isPlaying ? 1 : 0.965)
                .animation(.spring(response: 0.36, dampingFraction: 0.84), value: player.isPlaying)

                // 歌曲信息
                HStack(spacing: ScreenAdapter.w(12)) {
                    VStack(alignment: .leading, spacing: ScreenAdapter.h(4)) {
                        Text(track?.name ?? "未在播放")
                            .font(.system(size: ScreenAdapter.h(18), weight: .bold))
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)
                        Group {
                            if let t = track {
                                NowPlayingTrackDestinationLinks(
                                    track: t,
                                    font: .system(size: ScreenAdapter.h(13), weight: .medium),
                                    color: secondaryColor,
                                    onOpenDestination: onOpenDestination
                                )
                            } else {
                                Text(subtitle)
                                    .font(.system(size: ScreenAdapter.h(13), weight: .medium))
                                    .foregroundStyle(secondaryColor)
                                    .lineLimit(1)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                    }
                    Spacer(minLength: ScreenAdapter.w(8))
                    PlayerLikeButton(
                        track: track,
                        primaryColor: primaryColor,
                        accentColor: accentColor
                    )
                    moreMenu
                }
                .frame(maxWidth: artworkSize + ScreenAdapter.w(120))
                .padding(.top, ScreenAdapter.h(20))

                // 进度条 + 控制按钮 + 音量条 + 底部按钮
                VStack(spacing: 0) {
                    PlayerSeekBar()
                        .frame(maxWidth: artworkSize + ScreenAdapter.w(120))

                    Spacer().frame(height: ScreenAdapter.h(8))

                    HStack(spacing: ScreenAdapter.w(28)) {
                        Button {
                            player.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: ScreenAdapter.h(26), weight: .semibold))
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.88))

                        PlayPauseButton(isPlaying: player.isPlaying, size: ScreenAdapter.h(32)) {
                            player.togglePlayPause()
                        }
                        .foregroundStyle(primaryColor)

                        Button {
                            player.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: ScreenAdapter.h(26), weight: .semibold))
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.88))
                    }
                    .foregroundStyle(primaryColor)

                    Spacer().frame(height: ScreenAdapter.h(16))

                    // 音量条
                    PlayerVolumeControl()
                        .frame(maxWidth: artworkSize + ScreenAdapter.w(120))

                    Spacer().frame(height: ScreenAdapter.h(16))

                    // 底部按钮
                    HStack(spacing: ScreenAdapter.w(40)) {
                        playerToolbarButton(icon: "quote.bubble", active: showLyrics) {
                            // 无歌词也能进歌词界面（页内有「暂无歌词」空态占位）
                            showLyrics.toggle()
                        }
                        playerToolbarButton(icon: "text.bubble", active: showComments) {
                            showComments = true
                        }
                        playerToolbarButton(icon: "list.bullet") {
                            showQueue = true
                        }
                    }
                }
                .padding(.top, ScreenAdapter.h(20))

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ScreenAdapter.w(40))

            // 右侧：AMLL 歌词（如果开启了 AMLL）或普通歌词
            if settings.appleMusicUseAMLL {
                // 横屏：AMLL 歌词页占据右侧这一栏。
                // 轻量页（403KB、无 WebGL 背景）本身不渲染背景层，
                // 背景由 `playerBackground` 的模糊封面承担。
                AMLLWebLyricsView(useAppleMusicSettings: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, ScreenAdapter.h(CGFloat(amllTopPx)))
                    .padding(.bottom, ScreenAdapter.h(CGFloat(amllBottomPx)))
                    .padding(.horizontal, ScreenAdapter.w(CGFloat(amllHorizPx)))
            } else if !lyrics.isEmpty {
                // 普通歌词：滚动视图
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: ScreenAdapter.h(22)) {
                            Color.clear.frame(height: ScreenAdapter.h(60))
                            ForEach(lyrics) { line in
                                lyricLine(line, isFocused: line.id == currentVisualLyricID)
                                    .id(line.id)
                            }
                            Color.clear.frame(height: ScreenAdapter.h(60))
                        }
                        .padding(.horizontal, ScreenAdapter.w(24))
                    }
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.1),
                                .init(color: .black, location: 0.9),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            scrollToPlaybackLyric(proxy: proxy, animated: false)
                        }
                    }
                    .onChange(of: currentPlaybackLyricID) { _ in
                        guard !isDraggingLyrics else { return }
                        scrollToPlaybackLyric(proxy: proxy, animated: true)
                    }
                    .simultaneousGesture(
                        DragGesture().onChanged { _ in
                            isDraggingLyrics = true
                            resumeTask?.cancel()
                            resumeTask = Task {
                                try? await Task.sleep(for: .seconds(3))
                                guard !Task.isCancelled else { return }
                                isDraggingLyrics = false
                            }
                        }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, ScreenAdapter.w(40))
            } else {
                // 无歌词时显示占位
                VStack(spacing: ScreenAdapter.h(10)) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: ScreenAdapter.h(36), weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("暂无歌词")
                        .font(.system(size: ScreenAdapter.h(15), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.vertical, size.height < 500 ? ScreenAdapter.h(16) : ScreenAdapter.h(32))
    }

    // MARK: - 背景

    /// 背景层的参数装配。
    ///
    /// ⚠️ 真正的绘制在独立子视图 `AppleMusicPlayerBackground` 里，**不是**在这里直接铺开。
    /// 原因：背景层内含 AMLL 的 `WKWebView`（WebGL 歌词层）。若把它直接内联在本视图的
    /// `body` 中，那么本视图**任何**一次 `body` 重算（进度游标换行、设置变更、
    /// 切歌词页…）都会重新构造 WebView 的 representable，触发一次 `updateUIView`
    /// （重新下发 JS / 重建触摸处理器）。滑动歌词时游标频繁换行 → WebView 被反复
    /// 重新配置，表现为「歌词界面上下滑动很卡」。
    ///
    /// 抽成独立子视图后，只要下面这几个参数没变，SwiftUI 就**跳过**该子视图的
    /// `body` 重算，WebView 完全不受本视图重算的影响。
    @ViewBuilder
    private var playerBackground: some View {
        AppleMusicPlayerBackground(
            isDark: bgMode == .dark,
            // ★ 下方参数见 backgroundStyleUsesFluid / backgroundStyleDimScale
            // 压暗/提亮遮罩的强度，由「播放器调整」里的「背景暗度」控制。
            // 默认 0.48 —— 白字在暗底上清晰，同时封面还留得住细节。
            dim: CGFloat(min(max(bgDim, 0), 1)),
            usesFluidBackground: settings.appleMusicFluidBackground,
            usesAMLL: settings.appleMusicUseAMLL,
            showsLyrics: showLyrics,
            lyricsEngineNative: settings.appleMusicLyricsEngine == "native",
            coverURL: coverURL,
            amllTopPadding: ScreenAdapter.h(CGFloat(amllTopPx)),
            // ★ 2026-10-16 第十轮问题10：歌词页下滑收起底部控制后，歌词一直铺到
            //   手机底部（上滑恢复原状）
            amllBottomPadding: ScreenAdapter.h(hideBottomControls ? 12 : CGFloat(amllBottomPx)),
            amllHorizontalPadding: ScreenAdapter.w(CGFloat(amllHorizPx))
        )
    }

    // MARK: - 封面页

    private func coverPage(size: CGSize) -> some View {
        let contentWidth = max(size.width - ScreenAdapter.w(64), 0)
        let artworkSize = min(contentWidth, min(size.height * 0.50, ScreenAdapter.h(390)))
        let titleSize = trackTitleFontSize
        let artistSize = trackArtistFontSize
        let infoEntry = layoutEntry(.title)

        return VStack(spacing: 0) {
            Color.clear.frame(height: ScreenAdapter.h(160))

            // 大封面占位符（记录位置）
            //
            // ★ 需求 17：点击大封面打开歌词页。这里给占位符挂点击手势
            //   （真正的封面绘制层是 `allowsHitTesting(false)` 的，不吃点击）。
            Color.clear
                .frame(width: artworkSize, height: artworkSize)
                .contentShape(Rectangle())
                .onTapGesture {
                    // ★ 用户明确要求：点击大封面开歌词页不要震动（2026-10-14）。
                    guard !lyrics.isEmpty else { return }
                    showLyrics = true
                }
                .anchorPreference(
                    key: AppleMusicArtworkFrameKey.self,
                    value: .bounds
                ) { [.expanded: $0] }

            if settings.showLyricPreview {
                // 歌名/歌手信息与下方进度条**同宽同边距**（需求：左对齐进度条开头）；
                // 五角星与三点**右对齐进度条结尾**。
                HStack(spacing: ScreenAdapter.w(12)) {
                    VStack(alignment: .leading, spacing: ScreenAdapter.h(5)) {
                        HStack(spacing: ScreenAdapter.w(9)) {
                            Text(track?.name ?? "未在播放")
                                .font(.system(size: ScreenAdapter.h(titleSize), weight: .bold))
                                .foregroundStyle(primaryColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Group {
                            if let t = track {
                                NowPlayingTrackDestinationLinks(
                                    track: t,
                                    font: .system(size: ScreenAdapter.h(artistSize), weight: .medium),
                                    color: secondaryColor,
                                    onOpenDestination: onOpenDestination
                                )
                            } else {
                                Text(subtitle)
                                    .font(.system(size: ScreenAdapter.h(artistSize), weight: .medium))
                                    .foregroundStyle(secondaryColor)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                    }
                    Spacer(minLength: ScreenAdapter.w(8))
                    PlayerLikeButton(
                        track: track,
                        primaryColor: primaryColor,
                        accentColor: accentColor
                    )
                    moreMenu
                }
                .frame(maxWidth: Self.contentMaxWidth)
                .padding(.horizontal, Self.infoHorizontalPadding)
                .padding(.top, ScreenAdapter.h(22))
                .offset(x: infoEntry.x, y: infoEntry.y)

                MiniLyricsPreview {
                    guard !lyrics.isEmpty else { return }
                    WellHaptics.tap()
                    showLyrics = true
                }
                .padding(.top, ScreenAdapter.h(36))
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previewLyric)))
            } else {
                compactTrackHeader
                    .padding(.horizontal, Self.infoHorizontalPadding)
                    .padding(.top, ScreenAdapter.h(40))
                    .offset(x: infoEntry.x, y: infoEntry.y)
            }

            Spacer(minLength: 0).frame(height: ScreenAdapter.h(24))
        }
        // ⚠️ 这里**不**加水平内边距：歌名/歌手行自己带 `infoHorizontalPadding`，
        //    必须与 `playbackControls`（进度条所在容器）一致才能左右对齐。
        //    封面占位符另外用 `padding` 控制（见上），互不影响。
    }

    private var compactTrackHeader: some View {
        HStack(spacing: ScreenAdapter.w(12)) {
            VStack(alignment: .leading, spacing: ScreenAdapter.h(4)) {
                Text(track?.name ?? "未在播放")
                    .font(.system(size: ScreenAdapter.h(16), weight: .semibold))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                Group {
                    if let t = track {
                        NowPlayingTrackDestinationLinks(
                            track: t,
                            font: .system(size: ScreenAdapter.h(12), weight: .medium),
                            color: secondaryColor,
                            onOpenDestination: onOpenDestination
                        )
                    } else {
                        Text(subtitle)
                            .font(.system(size: ScreenAdapter.h(12), weight: .medium))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            PlayerLikeButton(
                track: track,
                primaryColor: primaryColor,
                accentColor: accentColor
            )
            moreMenu
        }
        .frame(maxWidth: ScreenAdapter.w(420))
    }

    // MARK: - 下滑关闭

    /// 竖屏内容统一水平内边距 / 最大宽度。
    ///
    /// **必须与 `playbackControls` 一致**：歌名歌手行、进度条、控制按钮、
    /// 音量条、底部按钮全部挂同一组数值，这样「歌名左缘 == 进度条左缘」、
    /// 「五角星/三点右缘 == 进度条右缘」自然成立。
    private static let infoHorizontalPadding = ScreenAdapter.w(24)
    private static let contentMaxWidth = ScreenAdapter.w(420)

    private static let dismissIndicatorWidth: CGFloat = 44
    private static let dismissIndicatorHeight: CGFloat = 5
    private static let dismissIndicatorHitWidth: CGFloat = 180
    private static let dismissIndicatorHitHeight: CGFloat = 82
    /// 松手时判定「要关闭」的位移阈值（点）。
    ///
    /// ★ 从 110 放宽到 95：热区扩大后，用户的预期是「拖过一小段就关」，
    ///   原来的 110 配小热区正是「难触发」体感的来源之一。
    ///
    /// ⚠️ `fileprivate`（而非 `private`）：跟手位移的判定在薄壳
    ///   `PlayerDismissDragContainer` 里，它同文件但不同类型。
    fileprivate static let dismissDistance: CGFloat = 95
    /// 松手时的**预测**位移阈值：快速轻扫的真实位移可能很小，用预测值补足手感。
    ///
    /// ★ 从 190 放宽到 130：轻扫（位移小、速度快）更容易触发关闭。
    fileprivate static let dismissPrediction: CGFloat = 130

    /// 顶部的下滑关闭指示条。
    ///
    /// 这个胶囊是**视觉提示**（告诉用户这里可以往下拖）+ **精确热区**：
    /// 拖它用 3pt 最小位移，最灵敏。整页热区见 `coverDismissGesture`
    /// （挂在 `coverPage` 上，封面任意位置都能下滑关闭）——两者是同一套
    /// 关闭逻辑，指示条只负责「看起来能拖」和「拖起来最灵敏」。
    ///
    /// ⚠️ 播放页是用 `fullScreenCover` 呈现的，系统不提供整页下滑关闭。
    /// 之前只声明了 `allowsNowPlayingDismiss` 这个环境键，但全项目没有任何地方
    /// 读它 —— 结果是「进入播放器后向下滑动退不出来」。
    private var dismissIndicator: some View {
        ZStack(alignment: .top) {
            Color.clear

            Capsule()
                .fill(.white.opacity(0.38))
                .frame(width: Self.dismissIndicatorWidth, height: Self.dismissIndicatorHeight)
                .padding(.top, 1)
        }
        .frame(width: Self.dismissIndicatorHitWidth, height: Self.dismissIndicatorHitHeight)
        .contentShape(Rectangle())
        .gesture(dismissDragGesture)
        .accessibilityLabel("下滑关闭播放页")
    }

    /// 下滑关闭手势工厂。
    ///
    /// ⚠️ 必须用 `.global` 坐标系：指示条自己会跟着手指下移，
    /// 若用局部坐标，手指与「移动中的热区」会互相反馈震荡。
    ///
    /// - Parameter minimumDistance: 触发拖拽所需的最小位移。顶部指示条是
    ///   **精确目标**，用 3pt 保证灵敏；铺满大封面的整页热区用 8pt，
    ///   避免点击/轻扫时误触发。
    private func makeDismissDragGesture(minimumDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
            .onChanged { value in
                guard !showLyrics else { return }
                // 只接受「向下」且**垂直分量大于水平分量**的拖拽：
                // 向上拖不动页面，横向滑（比如封面上的左右扫歌）也不该把页面拽下来。
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                // 位移交给薄壳。它内部用 `max(_, 0)` 夹取，所以手指拖回起点上方时
                // 页面会跟随回位到 0，而不是停在最后一次的正位移上。
                dismissDriver.onChanged(isDownward ? translation.height : 0)
            }
            .onEnded { value in
                guard !showLyrics else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissDriver.onEnded(
                    isDownward ? translation.height : 0,
                    isDownward ? value.predictedEndTranslation.height : 0
                )
            }
    }

    /// 顶部指示条 / 隐藏指示条后的透明热区用的下滑关闭手势（精确目标，灵敏）。
    private var dismissDragGesture: some Gesture {
        makeDismissDragGesture(minimumDistance: 3)
    }

    /// 大封面整页热区用的下滑关闭手势。
    ///
    /// ★ 原来只有顶部 180×82 的指示条能下滑关闭，用户在封面上往下滑
    /// 没有任何反应（「大封面状态下下滑很难触发」）。现在整张封面页
    /// （控制栏以上全部）都是热区，与 Apple Music 全屏播放器
    /// 「在封面区域下滑即收起」的手感一致。
    private var coverDismissGesture: some Gesture {
        makeDismissDragGesture(minimumDistance: 8)
    }

    // MARK: - 歌词页

    /// 歌词页顶部横条的下滑关闭手势。
    ///
    /// 始终返回同一类型的 `some Gesture`（不能返回 `Optional<Gesture>`），
    /// 是否启用交给 `.gesture(_:including:)` 决定。
    ///
    /// ★ 这里驱动的是**薄壳**里的跟手位移（与大封面下滑关闭走同一条视觉通路），
    ///   而不是给歌词页单独加 `.offset`。
    ///   原因：歌词页底层是 WebView 歌词层，对它所在的子树叠加位移 / 透明度
    ///   会强制 WebView 进离屏合成层，导致歌词与头部错位渗色。复用外层通路则完全
    ///   不动歌词页自身布局。
    ///
    /// ★ 最小位移从 8pt 收紧到 3pt（与系统原生播放器一致）：歌词页顶部这块
    ///   热区在手指刚动时就该接管，8pt 会让「开始下滑」有一段无响应的空档，
    ///   体感上就是「滑半天没反应」。
    private var headerDismissGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard showLyrics else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissDriver.onChanged(isDownward ? translation.height : 0)
            }
            .onEnded { value in
                guard showLyrics else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissDriver.onEnded(
                    isDownward ? translation.height : 0,
                    isDownward ? value.predictedEndTranslation.height : 0
                )
            }
    }

    private var lyricsPage: some View {
        VStack(spacing: 0) {
            // 顶部下滑关闭热区：视觉指示条 + 歌名/歌手行**整块**。
            //
            // ★ 原来只有 ~70pt 的指示条本身能下滑关闭，用户从头部文字、
            //   缩略封面那一带往下滑没有任何反应 —— 「歌词页下滑很难触发」
            //   的根源。现在把指示条 + `lyricsHeader` 包成一块热区：从屏幕
            //   顶端一直到「喜欢 / 更多」这一条都能下滑关页。歌词本体留给
            //   下方滚动区 / AMLL 层（Apple Music 歌词页同样只在顶部区域收）。
            VStack(spacing: 0) {
                // ★ 2026-10-15 用户：歌词页的小横条要与大封面状态的**完全一致**
                //   （44×5、white 0.38、屏幕顶部同一高度）。这里的容器起点比
                //   屏幕顶低 `headerTopSpacing`（portraitLayout 顶部的占位），
                //   用 offset 补偿回去，视觉位置与大封面的 dismissIndicator 对齐。
                ZStack(alignment: .top) {
                    Color.clear
                    Capsule()
                        .fill(.white.opacity(0.38))
                        .frame(width: 44, height: 5)
                        .offset(y: -(PlayerLayoutMetrics.headerTopSpacing + 1))
                }
                .frame(height: max(Self.safeAreaTopInset + ScreenAdapter.h(24), ScreenAdapter.h(70)))
                .contentShape(Rectangle())

                lyricsHeader
                    .padding(.horizontal, ScreenAdapter.w(24))
                    .padding(.top, ScreenAdapter.h(85))
                    .padding(.bottom, ScreenAdapter.h(10))
                    // 歌词页顶部整行整体位置（独立于大封面状态的 `.title`）
                    .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.lyricsHeader)))
            }
            .contentShape(Rectangle())
            // ⚠️ 不要写 `showLyrics ? DragGesture… : nil`：`nil` 无法参与
            // `Gesture` 推断，`showLyrics == false` 时会在附件手势那一刻
            // 解包失败直接崩溃。改为永远附加同一个手势，用 `including`
            // 在未展开歌词页时把它禁掉。
            //
            // ⚠️ `GestureMask` 只有 `.all` / `.subviews` / `.none` 三个成员。
            //
            // ★ `.all`：拖拽优先于块内的喜欢/更多/歌名链接按钮。这些按钮只响应
            //   **点击**，而 DragGesture 要移动 ≥8pt 才会识别，所以点击不受影响；
            //   真正拖动时由关闭手势接管 —— 正是想要的行为。
            .gesture(headerDismissGesture, including: showLyrics ? .all : .subviews)

            if settings.appleMusicUseAMLL {
                // AMLL 已在底层渲染歌词（`playerBackground` 里的 WebView），这里只保留头部。
                //
                // ★★ 2026-10-14 用户反馈「歌词页面下滑半天都没用」的**根因**就在这里：
                //    这块透明填充**默认会被 SwiftUI 当成可点击视图**（和本文件里
                //    `.opacity(0)` 的封面页吃点击是同一类问题，见第 365 行的说明），
                //    而它盖在底层 AMLL 的 `WKWebView` 之上 —— 于是歌词页区域的
                //    **所有触摸都被它吞掉**：既滚不动歌词、也点不了歌词跳转。
                //    AMLL 页面自己实现了触摸滚动（`scrollView.isScrollEnabled = false`
                //    + 页面内 touchstart/move 驱动），所以必须把触摸真正递给 WebView。
                Color.clear
                    .frame(maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else if lyrics.isEmpty {
                emptyLyricsView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: ScreenAdapter.h(26)) {
                            Color.clear.frame(height: lyricTopSpacer)
                            ForEach(lyrics) { line in
                                lyricRow(line)
                            }
                            Color.clear.frame(height: lyricBottomSpacer)
                        }
                        .padding(.horizontal, 28)
                    }
                    .coordinateSpace(name: Self.lyricsViewportSpace)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black, location: 0.12),
                                .init(color: .black, location: 0.84),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .background {
                        GeometryReader { viewport in
                            Color.clear
                                .onAppear { lyricsViewportHeight = viewport.size.height }
                                .onChange(of: viewport.size.height) { lyricsViewportHeight = $0 }
                        }
                    }
                    .onPreferenceChange(LyricLineCenterKey.self) { centers in
                        // ⚠️ 写进**不可观察**的盒子（不是 @State）：滚动时这里每帧都会来，
                        //    写 @State 会让整页每帧重算。详见 `LyricCenterBox` 的说明。
                        lyricCentersBox.value = centers
                        updateFocusedLyric(from: centers)
                    }
                    .simultaneousGesture(lyricsDragGesture(proxy: proxy))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            scrollToPlaybackLyric(proxy: proxy, animated: false)
                        }
                    }
                    .onChange(of: currentPlaybackLyricID) { _ in
                        guard !isDraggingLyrics else { return }
                        scrollToPlaybackLyric(proxy: proxy, animated: true)
                    }
                    .onChange(of: track?.id) { _ in
                        resumeTask?.cancel()
                        isDraggingLyrics = false
                        focusedLyricID = nil
                    }
                }
            }
        }
    }

    private var lyricsHeader: some View {
        HStack(spacing: ScreenAdapter.w(12)) {
            // 小封面占位符（记录位置）
            //
            // ★ 需求 17：点击小封面返回大封面状态（收起歌词页）。
            Color.clear
                .frame(width: ScreenAdapter.h(54), height: ScreenAdapter.h(54))
                .contentShape(Rectangle())
                .onTapGesture {
                    // ★ 用户明确要求：歌词页点击小封面返回不要震动（2026-10-14）。
                    showLyrics = false
                }
                .anchorPreference(
                    key: AppleMusicArtworkFrameKey.self,
                    value: .bounds
                ) { [.compact: $0] }

            VStack(alignment: .leading, spacing: ScreenAdapter.h(3)) {
                HStack(spacing: ScreenAdapter.w(7)) {
                    Text(track?.name ?? "未在播放")
                        .font(.system(size: ScreenAdapter.h(trackTitleFontSize * 0.68), weight: .semibold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Group {
                    if let t = track {
                        NowPlayingTrackDestinationLinks(
                            track: t,
                            font: .system(size: ScreenAdapter.h(trackArtistFontSize * 0.89), weight: .medium),
                            color: secondaryColor,
                            onOpenDestination: onOpenDestination
                        )
                    } else {
                        Text(subtitle)
                            .font(.system(size: ScreenAdapter.h(trackArtistFontSize * 0.89), weight: .medium))
                            .foregroundStyle(secondaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            // 歌词页歌名/歌手文字块单独位置（与「整行」独立叠加）
            .offset(x: layoutEntry(.lyricsTrackInfo).x,
                    y: layoutEntry(.lyricsTrackInfo).y)
            Spacer(minLength: 0)
            PlayerLikeButton(
                track: track,
                primaryColor: primaryColor,
                accentColor: accentColor
            )
            moreMenu
        }
    }

    // MARK: - 播放控制栏

    private func playbackControls(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            PlayerSeekBar()
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.progress)))

            Spacer().frame(height: ScreenAdapter.h(5))

            HStack(spacing: ScreenAdapter.h(36)) {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: ScreenAdapter.h(32), weight: .semibold))
                }
                .buttonStyle(.plain)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previous)))

                PlayPauseButton(isPlaying: player.isPlaying, size: ScreenAdapter.h(38)) {
                    player.togglePlayPause()
                }
                .frame(width: ScreenAdapter.h(80), height: ScreenAdapter.h(80))
                .foregroundStyle(primaryColor)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.play)))

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: ScreenAdapter.h(32), weight: .semibold))
                }
                .buttonStyle(.plain)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.next)))
            }
            .foregroundStyle(primaryColor)
            .frame(maxWidth: ScreenAdapter.w(320))

            Spacer().frame(height: ScreenAdapter.h(25))

            // 常驻音量条（替代底部音量按钮）
            PlayerVolumeControl()
                .frame(maxWidth: Self.contentMaxWidth)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.volume)))

            Spacer().frame(height: ScreenAdapter.h(30))

            HStack(spacing: ScreenAdapter.h(60)) {
                playerToolbarButton(icon: "quote.bubble", active: showLyrics) {
                    // 无歌词也能进歌词界面（页内有「暂无歌词」空态占位）
                    showLyrics.toggle()
                }
                playerToolbarButton(icon: "text.bubble", active: showComments) {
                    showComments = true
                }
                playerToolbarButton(icon: "list.bullet") {
                    showQueue = true
                }
            }
            .frame(maxWidth: Self.contentMaxWidth)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.actions)))
        }
        .padding(.horizontal, Self.infoHorizontalPadding)
        .padding(.top, ScreenAdapter.h(10))
        .padding(.bottom, ScreenAdapter.h(70))
        .gesture(commentsGesture)
        .scaleEffect(CGSize(width: 1.0, height: settings.appleMusicControlsHeight), anchor: .bottom)
    }

    private func playerToolbarButton(icon: String, active: Bool = false, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: ScreenAdapter.h(18), weight: .semibold))
                .foregroundStyle(active ? accentColor : primaryColor.opacity(0.78))
                .frame(width: ScreenAdapter.h(58), height: ScreenAdapter.h(58))
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.88))
    }

    private func compactActionButton(icon: String, active: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                // 用户要求：三点/五角星**不要太大**，与五角星同尺寸（17pt）。
                .font(.system(size: ScreenAdapter.h(17), weight: .semibold))
                .foregroundStyle(tint ?? (active ? accentColor : primaryColor.opacity(0.78)))
                .frame(width: ScreenAdapter.h(30), height: ScreenAdapter.h(30))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyLyricsView: some View {
        VStack(spacing: ScreenAdapter.h(10)) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: ScreenAdapter.h(34), weight: .light))
                .foregroundStyle(.white.opacity(0.42))
            Text("暂无歌词")
                .font(.system(size: ScreenAdapter.h(15), weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Text("点击封面区域返回歌曲页面")
                .font(.system(size: ScreenAdapter.h(12)))
                .foregroundStyle(.white.opacity(0.46))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            // 与大小封面保持一致：封面区域点击返回不震动（2026-10-14）。
            showLyrics = false
        }
    }

    // MARK: - 派生数据

    private var isVIP: Bool {
        guard let t = track else { return false }
        return t.fee == 1 || t.fee == 4
    }

    // 收藏按钮已抽成叶子视图 `PlayerLikeButton`（见 AppleMusicPlayerComponents.swift）。
    // 不要在播放页顶层直接读 `AccountStore`——那会把收藏状态的变化放大成整页重算。

    /// 播放模式图标：当前项目 repeatMode + shuffleEnabled 分离。
    private var playbackModeIcon: String {
        if player.shuffleEnabled { return "shuffle" }
        switch player.repeatMode {
        case .one: return "repeat.1"
        case .all: return "repeat"
        case .off: return "repeat"
        }
    }

    private var volumeIcon: String {
        switch player.volume {
        case 0: return "speaker.slash"
        case ..<0.4: return "speaker.wave.1"
        case ..<0.75: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }

    /// 当前应高亮的歌词行下标。
    ///
    /// ⚠️ 这里**不要**用 `clock.progress` 自己做二分查找。
    ///
    /// `clock`（`PlayerClock`）是 20Hz（50ms）刷新的时钟，`AppleMusicPlayerView`
    /// 一旦观察它，**整个播放器页的 body 每 50ms 就会全量重算一次** ——
    /// 而这棵树里有 AMLL 的 `WKWebView`、WebGL 全屏流动背景、封面插值动画层
    /// 和整条控制栏。播放时主线程会被彻底打满，表现就是「一打开播放器就卡死」。
    ///
    /// 改走 `lyricsCursor.activeIndex`：`LyricsCursor` 只在**当前行号真的变化时**
    /// 才写 `@Published`（它内部有 `if idx != activeIndex` 的判断），
    /// 所以重算频率从 20Hz 降到「一句歌词一次」——两行歌词之间的间隔通常好几秒。
    /// 代价是高亮最多滞后 100ms（`syncFromCore` 的轮询周期），完全不可感知。
    private var currentPlaybackLyricIndex: Int? {
        lyricsCursor.activeIndex
    }

    private var currentPlaybackLyricID: Int? {
        guard let index = currentPlaybackLyricIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }

    private var currentVisualLyricID: Int? {
        isDraggingLyrics ? focusedLyricID : (focusedLyricID ?? currentPlaybackLyricID)
    }

    private var subtitle: String {
        guard let t = track else { return "" }
        let parts = [t.artistNames, t.album.name].filter { !$0.isEmpty }
        return parts.isEmpty ? "未知歌曲" : parts.joined(separator: " · ")
    }

    private func lyricLine(_ line: LyricLine, isFocused: Bool) -> some View {
        // ★ 2026-10-16 用户问题11：歌词对齐方向（0 居中 / 1 左 / 2 右，设置里分段控制）
        let align: HorizontalAlignment = {
            switch lyricAlignment {
            case 1: return .leading
            case 2: return .trailing
            default: return .leading   // 居中由行内 Spacer 实现（见下）
            }
        }()
        let frameAlign: Alignment = {
            switch lyricAlignment {
            case 1: return .leading
            case 2: return .trailing
            default: return .center
            }
        }()
        return Button {
            WellHaptics.tap()
            player.seek(to: LyricTiming.seekTime(for: line, userOffset: lyricOffset))
        } label: {
            VStack(alignment: align, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if lyricAlignment != 1 { Spacer(minLength: 0) }
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: isFocused ? 27 : 23, weight: isFocused ? .bold : .semibold))
                        .foregroundStyle(primaryColor.opacity(isFocused ? 1 : 0.36))
                        .fixedSize(horizontal: false, vertical: true)
                    if isFocused && isDraggingLyrics {
                        Spacer(minLength: 8)
                        Text(playerTimeText(line.time))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(secondaryColor.opacity(0.82))
                    }
                    if lyricAlignment != 2 { Spacer(minLength: 0) }
                }
                if isFocused, let translation = line.translation, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(secondaryColor.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: frameAlign)
            .contentShape(Rectangle())
            .scaleEffect(isFocused ? 1.06 : 0.84, anchor: lyricAlignment == 2 ? .trailing : .leading)
            .blur(radius: isFocused ? 0 : 0.7)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isFocused)
    }

    // MARK: - 歌词滚动区辅助
    //
    // 刻意拆成独立成员：整段 `LazyVStack + ForEach + preference` 写在 `lyricsPage`
    // 一处时，Swift 的类型检查器会在合理时间内推不出来（CI 报
    // "unable to type-check this expression in reasonable time"）。
    // 拆出后每段表达式足够小，既修掉编译超时，也顺带可读性更好。

    /// 歌词列表顶部留白，让首行能滚到视口垂直中线。
    private var lyricTopSpacer: CGFloat {
        max(ScreenAdapter.h(88), lyricsViewportHeight * 0.30)
    }

    /// 歌词列表底部留白，让末行也能滚到中线。
    /// ★ 问题10：底部控制收起时收紧留白 —— 末行歌词也能到手机底部。
    private var lyricBottomSpacer: CGFloat {
        hideBottomControls ? 44 : max(110, lyricsViewportHeight * 0.34)
    }

    /// 单行歌词：本体 + 上报行中线位置。
    private func lyricRow(_ line: LyricLine) -> some View {
        let lineID = line.id
        return lyricLine(line, isFocused: lineID == currentVisualLyricID)
            .id(lineID)
            .background(lyricRowCenterReporter(lineID))
    }

    /// 把某一行的中线 y 值写进 `LyricLineCenterKey`。
    @ViewBuilder
    private func lyricRowCenterReporter(_ lineID: Int?) -> some View {
        GeometryReader { rowGeometry in
            let midY = rowGeometry.frame(in: .named(Self.lyricsViewportSpace)).midY
            Color.clear.preference(
                key: LyricLineCenterKey.self,
                value: Self.centerMap(id: lineID, midY: midY)
            )
        }
    }

    /// 构造只含一项的偏好字典。抽成静态方法避免 `Int?` 键在视图表达式里参与推断。
    private static func centerMap(id: Int?, midY: CGFloat) -> [Int: CGFloat] {
        guard let id else { return [:] }
        return [id: midY]
    }

    /// 歌词滚动视口的坐标空间名。
    private static let lyricsViewportSpace = "playerLyricsViewport"

    private func updateFocusedLyric(from centers: [Int: CGFloat]) {
        guard lyricsViewportHeight > 0, !centers.isEmpty else { return }
        let center = lyricsViewportHeight / 2
        let newID = centers.min { abs($0.value - center) < abs($1.value - center) }?.key
        // ⚠️ 只在**跨行**时才写 @State。
        //    这个函数被 `onPreferenceChange` 以**每帧**的频率调用（滚动中），
        //    旧写法无条件赋值 `focusedLyricID` → 即使高亮行根本没变，
        //    整页也被判定失效、每帧重算一次 —— 掉帧的直接来源之一。
        if newID != focusedLyricID { focusedLyricID = newID }
    }

    private func scrollToPlaybackLyric(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = currentPlaybackLyricID else { return }
        let action = { proxy.scrollTo(id, anchor: .center) }
        if animated {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) { action() }
        } else {
            action()
        }
    }

    private func lyricsDragGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // ⚠️ 本回调在拖动期间**每帧**触发。这里只允许做两件事：
                //    ① 把「用户正在滑」这一个布尔量置位（已经是 true 就不再写，
                //       重复写同值仍会产生一次视图失效）；
                //    ② 重启「3 秒后恢复跟随播放」的计时器。
                //
                //    曾经这里每帧还做：`updateFocusedLyric(...)`（与
                //    `onPreferenceChange` 里的调用重复）和用 `withAnimation`
                //    开一次 0.25s 的控制栏显隐动画 —— 每帧一次事务 + 每帧一次
                //    整页重算，连带底层的 WebView 歌词层被反复重新下发 JS。
                //    这正是「歌词页上下滑动很卡」的直接来源，现已移除。
                if !isDraggingLyrics { isDraggingLyrics = true }
                resumeTask?.cancel()
                resumeTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    isDraggingLyrics = false
                    if let currentID = currentPlaybackLyricID {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            proxy.scrollTo(currentID, anchor: .center)
                        }
                    }
                }
                // 底部控制区联动：下滑隐藏 / 上滑显示。
                // ★ 只在**跨过阈值**（±15pt）且目标状态真的改变时才写一次；
                //   原来的写法在死区外每帧都重申一遍 `withAnimation`。
                let translation = value.translation.height
                if translation > 15 {
                    if !hideBottomControls {
                        withAnimation(.easeInOut(duration: 0.25)) { hideBottomControls = true }
                    }
                } else if translation < -15 {
                    if hideBottomControls {
                        withAnimation(.easeInOut(duration: 0.25)) { hideBottomControls = false }
                    }
                }
            }
    }

    private var commentsGesture: some Gesture {
        DragGesture(minimumDistance: 25)
            .onEnded { value in
                guard value.translation.height < -54,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                guard track != nil else { return }
                WellHaptics.medium()
                showComments = true
            }
    }

    // MARK: - 颜色

    private var primaryColor: Color {
        if settings.appleMusicPrimaryHex.hasPrefix("#"),
           let color = Color(hex: settings.appleMusicPrimaryHex) { return color }
        return .white
    }

    private var secondaryColor: Color {
        if settings.appleMusicSecondaryHex.hasPrefix("#"),
           let color = Color(hex: settings.appleMusicSecondaryHex) { return color }
        return .white.opacity(0.58)
    }

    private var accentColor: Color {
        if settings.appleMusicAccentHex.hasPrefix("#"),
           let color = Color(hex: settings.appleMusicAccentHex) { return color }
        return Color(red: 1.0, green: 0.28, blue: 0.36)
    }

    private var volumeColor: Color {
        if settings.appleMusicVolumeHex.hasPrefix("#"),
           let color = Color(hex: settings.appleMusicVolumeHex) { return color }
        return primaryColor
    }

    // iOS 原生弹窗输入自定义睡眠定时
    //
    // ⚠️★ 2026-10-14 用户：「睡眠定时 → 自定义… 点了没有反应」。两个原因叠加：
    //   ① **present 目标错了**：播放页是 `fullScreenCover` 呈现的，系统 key window 的
    //      `rootViewController` **已经 present 了播放页**；再往它上面 present 新控制器，
    //      UIKit 只会打一行 "already presenting" 日志然后**静默丢弃**。
    //      修法：沿 `presentedViewController` 链走到**最顶层**的控制器再 present。
    //   ② **时机错了**：这个回调来自 SwiftUI 的 `Menu`（系统 UIMenu），菜单收起动画还没
    //      结束时立刻 present，同样会被丢掉。修法：延后一拍（0.35s）再弹。
    private func showCustomSleepTimerAlert() {
        // 先把要用的引用取出来（不让闭包去捕获整个视图结构体）
        let timer = player.sleepTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            var presenter: UIViewController?
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                if let key = scene.windows.first(where: { $0.isKeyWindow }) {
                    presenter = key.rootViewController
                    break
                }
            }
            if presenter == nil {
                for scene in scenes {
                    if let first = scene.windows.first {
                        presenter = first.rootViewController
                        break
                    }
                }
            }
            guard var top = presenter else { return }
            // 走到最顶层，否则 alert 会被 fullScreenCover 挡住/丢弃
            while let presented = top.presentedViewController { top = presented }

            let alert = UIAlertController(
                title: "自定义睡眠定时",
                message: "请输入分钟数（1-600）",
                preferredStyle: .alert
            )
            alert.addTextField { textField in
                textField.placeholder = "30"
                textField.keyboardType = .numberPad
                textField.text = "30"
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "开始", style: .default) { _ in
                if let text = alert.textFields?.first?.text,
                   let minutes = Int(text), minutes > 0 && minutes <= 600 {
                    timer.schedule(afterMinutes: minutes)
                }
            })
            top.present(alert, animated: true)
        }
    }
}

// MARK: - 睡眠定时子菜单

/// 三点菜单里的「睡眠定时」。
///
/// ⚠️★ 2026-10-14 用户：「睡眠定时我怎么刚打开自己就关闭了」。
///
/// 单独抽成一个视图，是为了让它**自己订阅** `SleepTimer`：
/// `AppleMusicPlayerView` 观察的是 `player`（`PlayerService`），而 `sleepTimer` 是
/// `PlayerService` 里**另一个** `ObservableObject` —— 在顶层读
/// `player.sleepTimer.state` 并不会订阅它的变化（`@EnvironmentObject` 只跟踪
/// `PlayerService.objectWillChange`）。后果是设好定时之后：
///   * 菜单左侧图标不会变成 `timer.circle.fill`；
///   * 「取消睡眠定时」那一行也不会出现；
/// 看起来就是「刚打开自己又关了」。放在这里用 `@ObservedObject` 订阅，状态一变立刻反映，
/// 同时把重算范围收敛到这一棵小子树（不放回播放页顶层，避免又一次全页重算）。
private struct SleepTimerMenu: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject var timer: SleepTimer
    let onCustom: () -> Void

    var body: some View {
        Menu {
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) 分钟") {
                    timer.schedule(afterMinutes: minutes)
                }
                .disabled(!player.hasCurrentTrack)
            }
            Button(action: onCustom) {
                Label("自定义...", systemImage: "slider.horizontal.3")
            }
            .disabled(!player.hasCurrentTrack)
            Button {
                timer.scheduleAtEndOfCurrentTrack()
            } label: {
                Label("当前歌曲结束时停止", systemImage: "music.note")
            }
            .disabled(!player.hasCurrentTrack)
            if timer.state.isActive {
                Divider()
                Button("取消睡眠定时", role: .destructive) {
                    timer.cancel()
                }
            }
        } label: {
            Label("睡眠定时", systemImage: timer.state.isActive ? "timer.circle.fill" : "timer")
        }
    }
}

// MARK: - 播放页背景

/// 播放页背景层：底色 + 流体渐变 / 封面模糊 + AMLL 歌词页。
///
/// 单独成一个视图是**性能要求**，不是风格偏好：它内含 `WKWebView`，
/// 必须挡在播放页顶层 `body` 的重算路径之外（详见
/// `AppleMusicPlayerView.playerBackground` 的说明）。只要下面这些参数不变，
/// SwiftUI 就会跳过本视图的 `body` 重算，WebView 不会被反复重新配置。
private struct AppleMusicPlayerBackground: View {
    let isDark: Bool
    let dim: CGFloat
    let usesFluidBackground: Bool
    let usesAMLL: Bool
    let showsLyrics: Bool
    /// ★ 歌词引擎：true = 原生 AppleMusic（移植版）
    let lyricsEngineNative: Bool
    let coverURL: URL?
    let amllTopPadding: CGFloat
    let amllBottomPadding: CGFloat
    let amllHorizontalPadding: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // 底层背景：暗色用黑色，浅色用白色
            (isDark ? Color.black : Color.white)
                .ignoresSafeArea()

            // 背景层：AMLL 同款「四色流体渐变」（默认）或封面模糊。
            //
            // 流体渐变是原生实现（FluidGradientBackground.swift）：只在 ≈48×106 的
            // 极低分辨率位图上逐帧取色/扭曲/旋转，再由 GPU 拉伸到全屏，
            // CPU 每帧 < 2ms —— 不会再重演「打开播放器就卡死」。
            if usesFluidBackground {
                FluidGradientBackground(url: coverURL)
                    .overlay(isDark ? Color.black.opacity(dim) : Color.white.opacity(dim))
                    .ignoresSafeArea()
            } else {
                CoverBlurBackground(url: coverURL, scheme: colorScheme)
                    .overlay(isDark ? Color.black.opacity(dim) : Color.white.opacity(dim))
                    .ignoresSafeArea()
            }

            // AMLL 歌词只在**展开歌词页时**才创建。
            //
            // ⚠️ 关键：这里**不能**写成「常驻 + opacity 控制」。历史上常驻配合
            // 官方 WebGL 完整页（478KB，带流动背景渲染器）意味着**打开播放器**
            // 就要加载整页并初始化 WebGL + 跑 GPU 着色器，正是「打开播放器就卡死」
            // 的直接元凶。现在页面已回退为轻量页（403KB、无 WebGL），恢复「点开
            // 歌词才创建」：打开播放器时根本不存在 WebView，从根上杜绝卡死。
            if usesAMLL && showsLyrics {
                // ★ 2026-10-16：歌词引擎二选一（播放器调整 → 歌词引擎）
                if lyricsEngineNative {
                    WellNativeLyricsHost(
                        topPadding: amllTopPadding,
                        bottomPadding: amllBottomPadding,
                        horizontalPadding: amllHorizontalPadding
                    )
                    .ignoresSafeArea()
                } else {
                    AMLLWebLyricsView(useAppleMusicSettings: true)
                        .ignoresSafeArea()
                        .padding(.top, amllTopPadding)
                        .padding(.bottom, amllBottomPadding)
                        .padding(.horizontal, amllHorizontalPadding)
                }
            }
        }
    }
}

// MARK: - 下滑关闭的跟手位移（薄壳）

/// 下滑关闭的驱动盒。
///
/// ## 为什么是「引用盒」而不是 `environment`
/// 拖拽位移是**每帧都要写**的高频状态。它有两个约束：
/// ① 播放页顶层不能持有它 —— 顶层含 WebView 歌词层，每写一次都会让整页重算，
///    连带 `updateUIView` 被反复调用（重新下发 JS），手感就是「不跟手、掉帧」；
/// ② 也不能用 `.environment(...)` 往下传 —— `EnvironmentValues` 的值每次
///    body 重算都会重新构造，环境值一变，读取它的播放页顶层照样会重算，
///    等于绕了一圈回到问题 ①。
///
/// 所以用引用类型做「闭包盒子」：盒子的**实例恒定**（由 `@State` 持有），
/// 薄壳把自己的 `Binding` 写进盒子；播放页顶层只是**读**盒子，不订阅它，
/// 于是拖拽期间顶层完全不重算，位移变化只重算薄壳自己的 body。
private final class PlayerDismissDragDriver {
    fileprivate var onChanged: (CGFloat) -> Void = { _ in }
    fileprivate var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
}

/// 只持有「下滑关闭跟手位移」这一组状态的**薄壳**容器。
///
/// ## 关闭时为什么保持 `isDragging = true`
/// 命中关闭阈值时**不动** `isDragging`，直接回调 `onDismiss()`：
/// 否则页面会先弹回原位再关闭，视觉上「弹一下」。
/// 未命中时，`isDragging` 与 `dragOffset` 必须放进**同一个**
/// `withAnimation` 事务里改 —— 否则赋值那一帧 offset 表达式就已经跳变回 0，
/// 弹簧动画作用在一个不再参与渲染的值上，表现为「松手瞬移」。
private struct PlayerDismissDragContainer<Content: View>: View {
    let driver: PlayerDismissDragDriver
    let onDismiss: () -> Void
    /// 是否允许下滑关闭（歌词页展开时由外部置 false）。
    let isEnabled: Bool
    let content: Content

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        content
            .offset(y: (isEnabled && isDragging) ? dragOffset : 0)
            .onAppear {
                // `fullScreenCover` 的内容视图可能被复用，残留位移会让播放器
                // 打开时就偏移半屏，所以每次出现都复位。
                dragOffset = 0
                isDragging = false

                // 把写入口接到本薄壳的 `@State` 上。捕获的是两个 `Binding`
                // （轻量、稳定，始终指向同一份 State 存储），而不是整个视图值。
                let offset = $dragOffset
                let dragging = $isDragging
                driver.onChanged = { translation in
                    dragging.wrappedValue = true
                    // 只接受向下的位移；`max` 夹取让手指拖回起点上方时页面跟随回位。
                    offset.wrappedValue = max(translation, 0)
                }
                driver.onEnded = { translation, predicted in
                    if translation > AppleMusicPlayerView.dismissDistance
                        || predicted > AppleMusicPlayerView.dismissPrediction {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            dragging.wrappedValue = false
                            offset.wrappedValue = 0
                        }
                    }
                }
            }
    }
}

// MARK: - 全屏播放页宿主透明化

/// 把 `fullScreenCover` 的**系统宿主视图链刷成透明**，消除「一整块白/黑页面粘着播放器下滑」。
///
/// ## 为什么需要它
/// 播放页由 `fullScreenCover` 呈现。系统会在我们的内容背后垫一层不透明宿主视图：
/// - 浅色模式 = 白色，深色模式 = 黑色；
/// - 这层宿主**不参与**我们自己的 `.offset(y:)` 位移。
///
/// 于是手动下滑关闭时，跟上手指的只有内容本身，宿主原地不动 →
/// 露出的那块就是「一整块白/黑板」，用户看到的就是「一整个页面粘着一起关」。
///
/// ## 做法
/// 一个零尺寸的 `UIViewControllerRepresentable`，挂到播放页 ZStack 的最底层。
/// 在 `updateUIViewController` 里沿 `parent` 链把**每一层**相关的
/// `view` / `containerView` / `presentedView` 背景都设为 `.clear`：
/// - 用自己的 VC 作锚点向上遍历，不改动全局 UI 外观（不像 nav/tab appearance 那样有副作用）；
/// - 宿主透明后，下滑露出的是**真正的下层 tab 页面**，观感与系统原生转场一致。
///
/// ⚠️ 必须放在 `DispatchQueue.main.async`：`makeUIViewController` 时机太早，
///    此时 `presentationController` 还没建立，直接取会拿到 nil。
struct PresentedSurfaceClearer: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// 是否已经排过「刷透明」的重试序列（只在首次 update 触发一次）。
        var scheduled = false
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // ⚠️ 2026-10-14 性能修正：**只在第一次**（以及随后几个时间点）做这件事。
        //
        // 旧实现每次 `updateUIViewController` 都 `DispatchQueue.main.async` 一次，
        // 再沿 `parent` 链把每层 view 的 `backgroundColor` 重设一遍。
        // 而 `updateUIViewController` 会随父视图**每次重算**被调用 ——
        // 播放页下滑关闭拖拽时就是**每帧**一次，等于每秒几十上百次遍历整条
        // 呈现视图链并改背景（每次改背景都要重新提交图层属性）→ 直接掉帧。
        //
        // 这件事本身是幂等的：宿主链在本次呈现期间不会变，做一次就够。
        // 但 `presentationController` 是**异步**建立的，太早做会拿到 nil，
        // 所以改成有界重试（0 / 0.05 / 0.2 / 0.6s）共 4 次，之后不再触碰。
        guard !context.coordinator.scheduled else { return }
        context.coordinator.scheduled = true
        let controller = uiViewController
        for delay in [0.0, 0.05, 0.2, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var current: UIViewController? = controller
                while let controller = current {
                    controller.view.backgroundColor = .clear
                    controller.parent?.view.backgroundColor = .clear
                    controller.presentationController?.containerView?.backgroundColor = .clear
                    controller.presentationController?.presentedView?.backgroundColor = .clear
                    current = controller.parent
                }
            }
        }
    }
}
