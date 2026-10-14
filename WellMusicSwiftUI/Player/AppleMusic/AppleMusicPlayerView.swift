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
    @Environment(\.colorScheme) private var colorScheme
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
    @AppStorage("wellmusic.lyricOffset") private var lyricOffset = 0.0
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
    @AppStorage("wellmusic.appleMusic.backgroundDim") private var bgDim: Double = 0.48
    @AppStorage("wellmusic.appleMusic.amllLyricTopPx") private var amllTopPx: Int = 140
    @AppStorage("wellmusic.appleMusic.amllLyricBottomPx") private var amllBottomPx: Int = 305
    @AppStorage("wellmusic.appleMusic.amllLyricHorizontalPx") private var amllHorizPx: Int = 10
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

    /// 整页下滑关闭时，页面跟随手指下移的距离。
    ///
    /// 只有**正在拖拽**时才作为 `.offset(y:)` 使用；其余时刻强制为 0，
    /// 避免旧值残留导致播放器打开时偏移半屏。
    @State private var dismissDragOffset: CGFloat = 0
    /// 是否正在执行下滑关闭拖拽。
    @State private var isDismissDragging = false

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
            // 下滑关闭的跟手位移。只有正在拖拽时才生效，
            // 否则强制 0 —— 免得残留值让播放器打开时偏移半屏。
            .offset(y: isDismissDragging ? dismissDragOffset : 0)
        }
        .ignoresSafeArea()
        // 歌词页面可见时禁用播放器下滑关闭手势，避免和歌词滚动手势冲突
        .environment(\.allowsNowPlayingDismiss, !showLyrics)
        .onChange(of: showLyrics) { _ in
            // 切换回大封面时重置底部控制区域隐藏状态
            hideBottomControls = false
        }
        .onAppear {
            // 复位下滑关闭状态：`fullScreenCover` 的内容视图可能被复用，
            // 残留的 dragOffset 会让播放器打开时就偏移半屏。
            dismissDragOffset = 0
            isDismissDragging = false
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

            // 复制链接
            Button {
                if let t = track {
                    let link: String
                    switch t.sourcePlatform {
                    case "tx":
                        link = "https://y.qq.com/n/ryqq/songDetail/\(t.platformSongId ?? "")"
                    case "kg":
                        link = "https://www.kugou.com/song/#hash=\(t.platformSongId ?? "")"
                    default:
                        link = "https://music.163.com/#/song?id=\(t.id)"
                    }
                    Platform.copyToPasteboard(string: link)
                    ToastCenter.shared.show("链接已复制")
                }
            } label: {
                Label("复制链接", systemImage: "link")
            }
        } label: {
            compactActionButton(icon: "ellipsis") {}
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
                DynamicCoverPlayer(url: dynamicURL)
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
                        DynamicCoverPlayer(url: dynamicURL)
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
                        .buttonStyle(.plain)

                        Button {
                            player.togglePlayPause()
                        } label: {
                            PlayPauseMorphIcon(isPlaying: player.isPlaying, size: ScreenAdapter.h(32))
                                .frame(width: ScreenAdapter.h(64), height: ScreenAdapter.h(64))
                                .foregroundStyle(primaryColor)
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.92))

                        Button {
                            player.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: ScreenAdapter.h(26), weight: .semibold))
                        }
                        .buttonStyle(.plain)
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
                            guard !lyrics.isEmpty else { return }
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

    @ViewBuilder
    private var playerBackground: some View {
        let isDark = bgMode == .dark
        // 压暗/提亮遮罩的强度，由「播放器调整」里的「背景暗度」控制。
        // 默认 0.48 —— 白字在暗底上清晰，同时封面还留得住细节。
        let dim = min(max(bgDim, 0), 1)
        ZStack {
            // 底层背景：暗色用黑色，浅色用白色
            (isDark ? Color.black : Color.white)
                .ignoresSafeArea()

            // 背景层：AMLL 同款「四色流体渐变」（默认）或封面模糊。
            //
            // 流体渐变是原生实现（FluidGradientBackground.swift）：只在 ≈48×106 的
            // 极低分辨率位图上逐帧取色/扭曲/旋转，再由 GPU 拉伸到全屏，
            // CPU 每帧 < 2ms —— 不会再重演「打开播放器就卡死」。
            if settings.appleMusicFluidBackground {
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
            if settings.appleMusicUseAMLL && showLyrics {
                AMLLWebLyricsView(useAppleMusicSettings: true)
                    .ignoresSafeArea()
                    .padding(.top, ScreenAdapter.h(CGFloat(amllTopPx)))
                    .padding(.bottom, ScreenAdapter.h(CGFloat(amllBottomPx)))
                    .padding(.horizontal, ScreenAdapter.w(CGFloat(amllHorizPx)))
            }
        }
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
    private static let dismissDistance: CGFloat = 95
    /// 松手时的**预测**位移阈值：快速轻扫的真实位移可能很小，用预测值补足手感。
    ///
    /// ★ 从 190 放宽到 130：轻扫（位移小、速度快）更容易触发关闭。
    private static let dismissPrediction: CGFloat = 130

    /// 顶部的下滑关闭指示条。
    ///
    /// 这个胶囊是**视觉提示**（告诉用户这里可以往下拖）+ **精确热区**：
    /// 拖它用 3pt 最小位移，最灵敏。整页热区见 `coverDismissGesture`
    /// （挂在 `coverPage` 上，封面任意位置都能下滑关闭）——两者是同一套
    /// 关闭逻辑，指示条只负责「看起来能拖」和「拖起来最灵敏」。
    ///
    /// ⚠️ 这里补的是 Kumone `IOSNowPlayingPresentation` 的缺失一环 ——
    /// 之前只移植了 `allowsNowPlayingDismiss` 这个环境键，但全项目没有任何地方
    /// 读它；而播放页是用 `fullScreenCover` 呈现的，系统不提供整页下滑关闭。
    /// 两者叠加的结果就是「进入播放器后向下滑动退不出来」。
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
                isDismissDragging = true
                // 只接受向下拖拽（正值）；向上拖不动页面。
                // 用 max 夹取：手指拖回起点上方时页面跟随回位到 0，
                // 而不是停在最后一次的正位移上。
                dismissDragOffset = max(value.translation.height, 0)
            }
            .onEnded { value in
                guard !showLyrics else { return }
                let translation = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if translation > Self.dismissDistance || predicted > Self.dismissPrediction {
                    // 关闭时**保持** `isDismissDragging = true`：
                    // 否则页面会先弹回原位再关闭，视觉上「弹一下」。
                    onDismiss()
                } else {
                    // ★ 修复「松手瞬移 / 掉帧」：`isDismissDragging` 必须放进
                    // `withAnimation` 块里一起改。之前的写法把它放在块外，
                    // `.offset(y:)` 的表达式（`isDismissDragging ? dragOffset : 0`）
                    // 在赋值那一帧就跳变成 0，弹簧动画作用在一个已经不参与
                    // 渲染的值上 —— 视觉上就是「松手后页面瞬移回去」。
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        isDismissDragging = false
                        dismissDragOffset = 0
                    }
                }
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
    /// ★ 这里驱动的是**外层容器**共用的 `isDismissDragging` / `dismissDragOffset`
    ///   （与大封面下滑关闭走同一条视觉通路），而不是给歌词页单独加 `.offset`。
    ///   原因：歌词页底层是 AMLL 的 `WKWebView`，对它所在的子树叠加位移 / 透明度
    ///   会强制 WebView 进离屏合成层，导致歌词与头部错位渗色。复用外层通路则完全
    ///   不动歌词页自身布局。
    private var headerDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard showLyrics else { return }
                isDismissDragging = true
                // 只接受向下拖拽；用 max 夹取，手指拖回起点上方时页面跟随回位。
                dismissDragOffset = max(value.translation.height, 0)
            }
            .onEnded { value in
                guard showLyrics else { return }
                let translation = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if translation > Self.dismissDistance || predicted > Self.dismissPrediction {
                    // 与大封面一致：关闭时保持 `isDismissDragging = true`，避免弹回再关。
                    onDismiss()
                } else {
                    // 同大封面：回弹必须带动画，否则 offset 表达式瞬移回 0。
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        isDismissDragging = false
                        dismissDragOffset = 0
                    }
                }
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
                ZStack {
                    Color.clear
                    Capsule()
                        .fill(.clear)
                        .frame(width: 36, height: 5)
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
                .frame(width: ScreenAdapter.h(48), height: ScreenAdapter.h(48))
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

                Button {
                    player.togglePlayPause()
                } label: {
                    PlayPauseMorphIcon(isPlaying: player.isPlaying, size: ScreenAdapter.h(38))
                        .frame(width: ScreenAdapter.h(80), height: ScreenAdapter.h(80))
                        .foregroundStyle(primaryColor)
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.92))
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
                    guard !lyrics.isEmpty else { return }
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
        .buttonStyle(.plain)
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
        Button {
            WellHaptics.tap()
            player.seek(to: LyricTiming.seekTime(for: line, userOffset: lyricOffset))
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: isFocused ? 27 : 23, weight: isFocused ? .bold : .semibold))
                        .foregroundStyle(primaryColor.opacity(isFocused ? 1 : 0.36))
                        .fixedSize(horizontal: false, vertical: true)
                    if isFocused && isDraggingLyrics {
                        Spacer(minLength: 8)
                        Text(wellamTimeString(line.time))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(secondaryColor.opacity(0.82))
                    }
                }
                if isFocused, let translation = line.translation, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(secondaryColor.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .scaleEffect(isFocused ? 1.06 : 0.84, anchor: .leading)
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
    private var lyricBottomSpacer: CGFloat {
        max(110, lyricsViewportHeight * 0.34)
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
                isDraggingLyrics = true
                resumeTask?.cancel()
                updateFocusedLyric(from: lyricCentersBox.value)
                // 下滑隐藏底部控制区域，上滑显示
                if value.translation.height > 15 {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        hideBottomControls = true
                    }
                } else if value.translation.height < -15 {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        hideBottomControls = false
                    }
                }
                // 和沉浸模式一致：拖动开始后 3 秒自动恢复跟随播放
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
    private func showCustomSleepTimerAlert() {
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
                player.sleepTimer.schedule(afterMinutes: minutes)
            }
        })
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            rootVC.present(alert, animated: true)
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
