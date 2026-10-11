import SwiftUI
import MediaPlayer
import UIKit

private struct ReferenceLyricCenterKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private enum AppleMusicArtworkAnchor: Hashable {
    case expanded
    case compact
}

private struct AppleMusicArtworkFrameKey: PreferenceKey {
    static var defaultValue: [AppleMusicArtworkAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [AppleMusicArtworkAnchor: Anchor<CGRect>], nextValue: () -> [AppleMusicArtworkAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private enum AppleMusicTextAnchor: Hashable {
    case titleExpanded
    case titleCompact
    case artistExpanded
    case artistCompact
}

private struct AppleMusicTextFrameKey: PreferenceKey {
    static var defaultValue: [AppleMusicTextAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [AppleMusicTextAnchor: Anchor<CGRect>], nextValue: () -> [AppleMusicTextAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ReferencePlaybackPresentationMetrics {
    static let headerTopSpacing: CGFloat = 20
}

/// Apple Music 风格全屏播放页：封面模糊背景 + 大封面/歌词页切换 + 底部控制栏。
/// 移植自 wellam 的 ReferencePlaybackView，数据接入当前项目的 PlayerService / Track / AccountStore。
struct AppleMusicPlayerView: View {
    let onOpenDestination: (Destination) -> Void
    let onDismiss: () -> Void

    /// 底部安全区域间距（不用GeometryReader，避免fullScreenCover动画过程中尺寸不正确）
    static var safeAreaBottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.bottom ?? 0
    }

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    /// 播放模式 / 歌词偏移等已迁到播放器菜单，需要观察 AppState 才能让勾选状态刷新
    @ObservedObject private var appState = AppState.shared
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared

    @State private var showLyrics = false
    @State private var headerDragOffset: CGFloat = 0
    /// 整页下滑关闭的跟手位移（负数=向上，不跟手；只跟正向位移）
    @State private var dismissDragOffset: CGFloat = 0
    /// 一次连续下拉手势里各子视图的累计位移，用来区分「下拉关闭」和「歌词上下滚动」
    @State private var dismissGestureActive = false
    @State private var showQueue = false
    @State private var showComments = false
    @State private var showAddToPlaylist = false
    @State private var showLyricOffsetSheet = false
    @State private var showVolumePopover = false
    @State private var layoutMode = false
    @State private var appleLayoutPart: AppleMusicLayoutPart = .cover
    @AppStorage("wellmusic.lyricOffset") private var lyricOffset = 0.0
    @AppStorage("wellmusic.appleMusic.showVolume") private var showVolumeControl = false
    @AppStorage("wellmusic.appleMusic.primaryHex") private var primaryHex = ""
    @AppStorage("wellmusic.appleMusic.secondaryHex") private var secondaryHex = ""
    @AppStorage("wellmusic.appleMusic.accentHex") private var accentHex = ""
    @AppStorage("wellmusic.appleMusic.volumeHex") private var volumeHex = ""
    @AppStorage("wellmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage("wellmusic.appleMusic.showLyricPreview") private var showLyricPreview = false
    @AppStorage("wellmusic.player.autoSkipOnFailure") private var autoSkipOnFailure = true
    @AppStorage("wellmusic.player.swipeSwitchSong") private var swipeSwitchSong = true
    @AppStorage("wellmusic.player.breath") private var breath = 0.6
    @AppStorage("wellmusic.player.progressBarStyle") private var progressBarStyle = 0
    @AppStorage("wellmusic.lyric.fontSize") private var lyricFontSize = 17.0
    @AppStorage("wellmusic.lyric.lineSpacing") private var lyricLineSpacing = 24.0
    @AppStorage("wellmusic.lyric.translation") private var lyricTranslation = true
    @AppStorage("wellmusic.lyric.glowLevel") private var lyricGlowLevel = 1
    @AppStorage("wellmusic.player.controlsUseCoverColor") private var controlsUseCoverColor = true

    @State private var lyricCenters: [Int: CGFloat] = [:]
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
        // 不用GeometryReader，避免fullScreenCover动画过程中尺寸不正确导致播放器只展开一半
        let screenSize = UIScreen.main.bounds.size
        let isLandscape = screenSize.width > screenSize.height

        ZStack {
            // 底层：playerBackground内部已集成AMLL（开启时）或原版背景
            playerBackground

            if isLandscape {
                // 横屏布局：左右分栏，参考沉浸模式regularLayout
                landscapeLayout(size: screenSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 竖屏布局：原有布局
                portraitLayout(size: screenSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: dismissDragOffset)
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
        .onChange(of: showLyrics) { _ in
            // 切换回大封面时重置底部控制区域隐藏状态
            hideBottomControls = false
        }
        .onAppear { if settings.dynamicCoverEnabled { dynamicCover.updateTrack(track) } }
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
                    QueueView()
                        .environmentObject(player)
                        .presentationDetents([.medium, .large])
                        .presentationBackground(.ultraThinMaterial)
                } else if #available(iOS 16.0, *) {
                    QueueView()
                        .environmentObject(player)
                        .presentationDetents([.medium, .large])
                } else {
                    QueueView()
                        .environmentObject(player)
                }
            }
        }
        .sheet(isPresented: $showComments) {
            Group {
                if let t = track {
                    CommentsView(track: t)
                }
            }
            .modifier(CommentsSheetDetents())
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let t = track {
                AddToPlaylistSheet(track: t)
            }
        }
        .sheet(isPresented: $showLyricOffsetSheet) {
            LyricOffsetSheet()
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

            // 下一首播放
            Button {
                if let t = track {
                    player.addToPlayNext(track: t)
                    ToastCenter.shared.show("已添加到下一首播放")
                }
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            // 加入歌单
            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单…", systemImage: "music.note.list")
            }

            Divider()

            // 播放模式（自设置页迁移到播放器界面）
            Menu {
                Button {
                    AppState.shared.playMode = 0
                } label: {
                    modeMenuLabel("列表循环", selected: AppState.shared.playMode == 0)
                }
                Button {
                    AppState.shared.playMode = 1
                } label: {
                    modeMenuLabel("单曲循环", selected: AppState.shared.playMode == 1)
                }
                Button {
                    AppState.shared.playMode = 2
                } label: {
                    modeMenuLabel("随机播放", selected: AppState.shared.playMode == 2)
                }
            } label: {
                Label("播放模式", systemImage: "repeat")
            }

            // 歌词偏移（自设置页迁移到播放器界面）
            Button {
                showLyricOffsetSheet = true
            } label: {
                Label("歌词偏移", systemImage: "timer")
            }

            // FLAC 精准同步（仅 AMLL 开启时显示）
            if settings.appleMusicUseAMLL {
                Button {
                    settings.preciseFLAC.toggle()
                } label: {
                    Label("FLAC 精准同步", systemImage: settings.preciseFLAC ? "checkmark.circle.fill" : "circle")
                }
            }

            // 睡眠定时（和沉浸模式V2一样，直接在菜单中显示选项）
            Menu {
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) 分钟") {
                        player.sleepTimer.schedule(afterMinutes: minutes)
                    }
                    .disabled(!player.hasCurrentTrack)
                }
                Button {
                    showCustomSleepTimerAlert()
                } label: {
                    Label("自定义...", systemImage: "slider.horizontal.3")
                }
                .disabled(!player.hasCurrentTrack)
                Button {
                    player.sleepTimer.scheduleAtEndOfCurrentTrack()
                } label: {
                    Label("当前歌曲结束时停止", systemImage: "music.note")
                }
                .disabled(!player.hasCurrentTrack)
                if player.sleepTimer.state.isActive {
                    Divider()
                    Button("取消睡眠定时", role: .destructive) {
                        player.sleepTimer.cancel()
                    }
                }
            } label: {
                Label("睡眠定时", systemImage: player.sleepTimer.state.isActive ? "timer.circle.fill" : "timer")
            }

            Divider()

            // 底部控制区域高度调节（仅 Apple Music 播放器）
            Menu {
                ForEach([0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5], id: \.self) { scale in
                    Button {
                        settings.appleMusicControlsHeight = scale
                    } label: {
                        if abs(settings.appleMusicControlsHeight - scale) < 0.01 {
                            Label("\(Int(scale * 100))%", systemImage: "checkmark")
                        } else {
                            Text("\(Int(scale * 100))%")
                        }
                    }
                }
            } label: {
                Label("底部区域高度", systemImage: "slider.vertical.3")
            }

            Divider()

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

    /// 播放模式菜单项：选中项带勾
    @ViewBuilder
    private func modeMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
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

    // MARK: - 整页下滑关闭

    /// 下拉关闭手势。
    ///
    /// 之前只有歌词页顶部一个 30pt 高的透明条绑定了下滑手势，且要求 `showLyrics == true`，
    /// 于是大封面页完全无法下滑关闭，用户只能卡在播放器里。这里改成整页跟手：
    /// - 只接管「纵向 + 向下」的拉拽，位移超过 10pt 且纵向比横向明显时才启动，避免抢走
    ///   歌词区的左右滑动 / 进度条拖动；
    /// - 跟手位移带阻尼（0.45），松手时超过屏高 18% 即关闭，否则弹回；
    /// - 关闭时先用 0.28s 把页面推下去再调 onDismiss，避免露出生硬的转场。
    private func swipeToDismissGesture(screenHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let dy = value.translation.height
                let dx = value.translation.width
                // 与歌词滚动 / 进度条拖动的边界：只在明显纵向下拉时接管
                if !dismissGestureActive {
                    guard dy > 10, abs(dy) > abs(dx) * 1.2 else { return }
                    dismissGestureActive = true
                }
                // 只跟正向位移，向上拉不跟手（阻尼 0.45）
                let offset = max(0, dy) * 0.45
                dismissDragOffset = offset
                headerDragOffset = offset
            }
            .onEnded { value in
                guard dismissGestureActive else { return }
                dismissGestureActive = false
                let shouldDismiss = value.translation.height > screenHeight * 0.18
                    || value.predictedEndTranslation.height > screenHeight * 0.35
                if shouldDismiss {
                    withAnimation(.easeIn(duration: 0.28)) {
                        dismissDragOffset = screenHeight
                        headerDragOffset = screenHeight
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        onDismiss()
                        // 复位，供下次进入时使用（fullScreenCover 关闭后视图会销毁，这里兜底）
                        dismissDragOffset = 0
                        headerDragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        dismissDragOffset = 0
                        headerDragOffset = 0
                    }
                }
            }
    }

    // MARK: - 竖屏布局

    private func portraitLayout(size: CGSize) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: ReferencePlaybackPresentationMetrics.headerTopSpacing)

            ZStack {
                coverPage(size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showLyrics ? 0 : 1)
                    // 大封面页没有内部滚动视图，可以整页接管下滑关闭（网易云同款手感）
                    .contentShape(Rectangle())
                    .gesture(showLyrics ? nil : swipeToDismissGesture(screenHeight: size.height))
                lyricsPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showLyrics ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlayPreferenceValue(AppleMusicArtworkFrameKey.self) { artworkFrames in
                    GeometryReader { proxy in
                        if let expanded = artworkFrames[.expanded],
                           let compact = artworkFrames[.compact] {
                            let expandedFrame = proxy[expanded]
                            let compactFrame = proxy[compact]
                            let targetFrame = showLyrics ? compactFrame : expandedFrame
                            let cornerRadius: CGFloat = showLyrics ? 10 : 18

                            ZStack {
                                // 封面图片始终作为底层
                                CoverImage(
                                    url: coverURL,
                                    size: targetFrame.width,
                                    cornerRadius: cornerRadius,
                                    emptyHint: player.isBuffering ? "等待开始播放…" : nil
                                )
                                .frame(width: targetFrame.width, height: targetFrame.height)
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                                // 动态封面视频叠加在上面
                                if settings.dynamicCoverEnabled, let dynamicURL = dynamicCover.coverURL {
                                    DynamicCoverPlayer(url: dynamicURL)
                                        .frame(width: targetFrame.width, height: targetFrame.height)
                                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                                }
                            }
                            .shadow(color: .black.opacity(showLyrics ? 0.26 : 0.46), radius: showLyrics ? 9 : 36, y: showLyrics ? 4 : 18)
                            .scaleEffect(showLyrics ? 1 : (player.isPlaying ? 1 : 0.965))
                            .position(x: targetFrame.midX, y: targetFrame.midY)
                            .allowsHitTesting(false)
                        }
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

    // MARK: - 横屏布局（参考沉浸模式regularLayout，左右分栏）

    private func landscapeLayout(size: CGSize) -> some View {
        // 横屏时封面尺寸：参考沉浸模式的计算方式
        let artworkSize = max(ScreenAdapter.h(120), min(ScreenAdapter.h(280), size.height * 0.55, size.width * 0.28))

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
                    compactActionButton(
                        icon: isLiked ? "heart.fill" : "heart",
                        active: isLiked
                    ) { onFavorite() }
                    moreMenu
                }
                .frame(maxWidth: artworkSize + ScreenAdapter.w(120))
                .padding(.top, ScreenAdapter.h(20))

                // 进度条 + 控制按钮 + 音量条 + 底部按钮
                VStack(spacing: 0) {
                    ReferenceScrubber()
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
                    ReferenceVolumeControl()
                        .frame(maxWidth: artworkSize + ScreenAdapter.w(120))

                    Spacer().frame(height: ScreenAdapter.h(16))

                    // 底部按钮
                    HStack(spacing: ScreenAdapter.w(40)) {
                        referenceActionButton(icon: "quote.bubble", active: showLyrics) {
                            guard !lyrics.isEmpty else { return }
                            showLyrics.toggle()
                        }
                        referenceActionButton(icon: "text.bubble", active: showComments) {
                            showComments = true
                        }
                        referenceActionButton(icon: "list.bullet") {
                            showQueue = true
                        }
                    }
                }
                .padding(.top, ScreenAdapter.h(20))

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, ScreenAdapter.w(40))

            // 右侧：AMLL歌词（如果开启了AMLL）或普通歌词
            if settings.appleMusicUseAMLL {
                // AMLL歌词：直接使用AMLLWebLyricsView
                AMLLWebLyricsView(useAppleMusicSettings: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, ScreenAdapter.h(CGFloat(settings.appleMusicAmllLyricTop)))
                    .padding(.bottom, ScreenAdapter.h(CGFloat(settings.appleMusicAmllLyricBottom)))
                    .padding(.horizontal, ScreenAdapter.w(CGFloat(settings.appleMusicAmllLyricHorizontal)))
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
        let isDark = settings.appleMusicBackgroundMode == .dark
        ZStack {
            // 底层背景：暗色用黑色，浅色用白色
            (isDark ? Color.black : Color.white)
                .ignoresSafeArea()

            // 模糊封面背景（AMLL 和非 AMLL 模式都有）
            CoverBlurBackground(url: coverURL, scheme: colorScheme)
                .overlay(isDark ? Color.black.opacity(0.48) : Color.white.opacity(0.35))
                .ignoresSafeArea()

            // AMLL 歌词只在展开歌词页时显示，大封面状态隐藏
            if settings.appleMusicUseAMLL && showLyrics {
                AMLLWebLyricsView(useAppleMusicSettings: true)
                    .ignoresSafeArea()
                    .padding(.top, ScreenAdapter.h(CGFloat(settings.appleMusicAmllLyricTop)))
                    .padding(.bottom, ScreenAdapter.h(CGFloat(settings.appleMusicAmllLyricBottom)))
                    .padding(.horizontal, ScreenAdapter.w(CGFloat(settings.appleMusicAmllLyricHorizontal)))
            }
        }
    }

    // MARK: - 封面页

    private func coverPage(size: CGSize) -> some View {
        let contentWidth = max(size.width - ScreenAdapter.w(64), 0)
        let artworkSize = min(contentWidth, min(size.height * 0.50, ScreenAdapter.h(390)))

        return VStack(spacing: 0) {
            Color.clear.frame(height: ScreenAdapter.h(160))

            // 大封面占位符（记录位置）
            Color.clear
                .frame(width: artworkSize, height: artworkSize)
                .anchorPreference(
                    key: AppleMusicArtworkFrameKey.self,
                    value: .bounds
                ) { [.expanded: $0] }

            if showLyricPreview {
                HStack(spacing: ScreenAdapter.w(12)) {
                    VStack(alignment: .leading, spacing: ScreenAdapter.h(5)) {
                        HStack(spacing: ScreenAdapter.w(9)) {
                            Text(track?.name ?? "未在播放")
                                .font(.system(size: ScreenAdapter.h(22), weight: .bold))
                                .foregroundStyle(primaryColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Group {
                            if let t = track {
                                NowPlayingTrackDestinationLinks(
                                    track: t,
                                    font: .system(size: ScreenAdapter.h(13.5), weight: .medium),
                                    color: secondaryColor,
                                    onOpenDestination: onOpenDestination
                                )
                            } else {
                                Text(subtitle)
                                    .font(.system(size: ScreenAdapter.h(13.5), weight: .medium))
                                    .foregroundStyle(secondaryColor)
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                    }
                    Spacer(minLength: ScreenAdapter.w(8))
                    compactActionButton(
                        icon: isLiked ? "heart.fill" : "heart",
                        active: isLiked
                    ) { onFavorite() }
                    moreMenu
                }
                .frame(maxWidth: ScreenAdapter.w(420))
                .padding(.top, ScreenAdapter.h(22))
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.title)))

                MiniLyricsPreview {
                    guard !lyrics.isEmpty else { return }
                    WellHaptics.tap()
                    showLyrics = true
                }
                .padding(.top, ScreenAdapter.h(36))
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previewLyric)))
            } else {
                compactTrackHeader
                    .padding(.top, ScreenAdapter.h(40))
            }

            Spacer(minLength: 0).frame(height: ScreenAdapter.h(24))
        }
        .padding(.horizontal, ScreenAdapter.w(32))
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
            compactActionButton(
                icon: isLiked ? "heart.fill" : "heart",
                active: isLiked
            ) { onFavorite() }
            moreMenu
        }
        .frame(maxWidth: ScreenAdapter.w(420))
    }

    // MARK: - 歌词页

    private var lyricsPage: some View {
        VStack(spacing: 0) {
            // 歌词页顶部下拉区：覆盖「横条 + 歌曲信息头」，下滑即关闭播放器。
            // 之前这块只有 30pt 高，手指很难命中；现在把歌曲信息头一起并入热区，
            // 但真正的歌词滚动区不受影响（手势只挂在这一段上）。
            VStack(spacing: 0) {
                // 顶部小横条（视觉上不可见，仅作抓取提示）
                Capsule()
                    .fill(.clear)
                    .frame(width: 36, height: 5)
                    .padding(.top, ScreenAdapter.h(10))
                    .padding(.bottom, ScreenAdapter.h(8))

                lyricsHeader
                    .padding(.horizontal, ScreenAdapter.w(24))
                    .padding(.top, ScreenAdapter.h(52))
                    .padding(.bottom, ScreenAdapter.h(10))
            }
            .contentShape(Rectangle())
            .offset(y: showLyrics ? headerDragOffset : 0)
            .gesture(showLyrics ? swipeToDismissGesture(screenHeight: UIScreen.main.bounds.height) : nil)

            if settings.appleMusicUseAMLL {
                // AMLL已在底层渲染歌词，这里只保留头部，剩余空间透明
                Color.clear.frame(maxHeight: .infinity)
            } else if lyrics.isEmpty {
                emptyLyricsView
            } else {
                lyricsScrollView
            }
        }
    }

    // MARK: - 歌词滚动区（独立子视图，避免类型检查超时）

    private func lyricRow(_ line: LyricLine, isFocused: Bool) -> some View {
        lyricLine(line, isFocused: isFocused)
            .id(line.id)
            .background {
                GeometryReader { rowGeometry in
                    Color.clear.preference(
                        key: ReferenceLyricCenterKey.self,
                        value: [(line.id ?? 0): rowGeometry.frame(in: .named("referenceLyricsViewport")).midY]
                    )
                }
            }
    }

    private var lyricsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: ScreenAdapter.h(26)) {
                    Color.clear.frame(height: max(ScreenAdapter.h(88), lyricsViewportHeight * 0.30))
                    ForEach(lyrics) { line in
                        lyricRow(line, isFocused: line.id == currentVisualLyricID)
                    }
                    Color.clear.frame(height: max(110, lyricsViewportHeight * 0.34))
                }
                .padding(.horizontal, 28)
            }
            .coordinateSpace(name: "referenceLyricsViewport")
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
                        .onChange(of: viewport.size.height) { height in
                            lyricsViewportHeight = height
                        }
                }
            }
            .onPreferenceChange(ReferenceLyricCenterKey.self) { centers in
                lyricCenters = centers
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

    private var lyricsHeader: some View {
        HStack(spacing: ScreenAdapter.w(12)) {
            // 小封面占位符（记录位置）
            Color.clear
                .frame(width: ScreenAdapter.h(48), height: ScreenAdapter.h(48))
                .anchorPreference(
                    key: AppleMusicArtworkFrameKey.self,
                    value: .bounds
                ) { [.compact: $0] }

            VStack(alignment: .leading, spacing: ScreenAdapter.h(3)) {
                HStack(spacing: ScreenAdapter.w(7)) {
                    Text(track?.name ?? "未在播放")
                        .font(.system(size: ScreenAdapter.h(15), weight: .semibold))
                        .foregroundStyle(primaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 0)
            compactActionButton(
                icon: isLiked ? "heart.fill" : "heart",
                active: isLiked
            ) { onFavorite() }
            moreMenu
        }
    }

    // MARK: - 播放控制栏

    private func playbackControls(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            ReferenceScrubber()
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
            ReferenceVolumeControl()
                .frame(maxWidth: ScreenAdapter.w(420))
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.volume)))

            Spacer().frame(height: ScreenAdapter.h(30))

            HStack(spacing: ScreenAdapter.h(60)) {
                referenceActionButton(icon: "quote.bubble", active: showLyrics) {
                    guard !lyrics.isEmpty else { return }
                    showLyrics.toggle()
                }
                referenceActionButton(icon: "text.bubble", active: showComments) {
                    showComments = true
                }
                referenceActionButton(icon: "list.bullet") {
                    showQueue = true
                }
            }
            .frame(maxWidth: ScreenAdapter.w(420))
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.actions)))
        }
        .padding(.horizontal, ScreenAdapter.w(24))
        .padding(.top, ScreenAdapter.h(10))
        .padding(.bottom, ScreenAdapter.h(70))
        .gesture(commentsGesture)
        .scaleEffect(CGSize(width: 1.0, height: settings.appleMusicControlsHeight), anchor: .bottom)
    }

    private func referenceActionButton(icon: String, active: Bool = false, tint: Color = .white, action: @escaping () -> Void) -> some View {
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

    private func compactActionButton(icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: ScreenAdapter.h(17), weight: .semibold))
                .foregroundStyle(active ? accentColor : primaryColor.opacity(0.78))
                .frame(width: ScreenAdapter.h(38), height: ScreenAdapter.h(38))
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
            WellHaptics.tap()
            showLyrics = false
        }
    }

    // MARK: - 派生数据

    private var isVIP: Bool {
        guard let t = track else { return false }
        return t.fee == 1 || t.fee == 4
    }

    private var isLiked: Bool {
        guard let t = track else { return false }
        return account.isLiked(track: t)
    }

    private func onFavorite() {
        guard let t = track else { return }
        Task { await AccountStore.shared.toggleLike(trackID: t.id, track: t) }
    }

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

    private var currentPlaybackLyricIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        let progress = LyricTiming.effectiveProgress(clock.progress, userOffset: lyricOffset)
        var low = 0
        var high = lyrics.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].time <= progress {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
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

    private func updateFocusedLyric(from centers: [Int: CGFloat]) {
        guard lyricsViewportHeight > 0, !centers.isEmpty else { return }
        let center = lyricsViewportHeight / 2
        focusedLyricID = centers.min { abs($0.value - center) < abs($1.value - center) }?.key
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
                updateFocusedLyric(from: lyricCenters)
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
                // 和沉浸模式一致：拖动开始后3秒自动恢复跟随播放
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
                guard value.translation.height < -54, abs(value.translation.height) > abs(value.translation.width) else { return }
                guard track != nil else { return }
                WellHaptics.medium()
                showComments = true
            }
    }

    // MARK: - 颜色

    private var primaryColor: Color {
        if primaryHex.hasPrefix("#"), let color = Color(hex: primaryHex) { return color }
        return .white
    }

    private var secondaryColor: Color {
        if secondaryHex.hasPrefix("#"), let color = Color(hex: secondaryHex) { return color }
        return .white.opacity(0.58)
    }

    private var accentColor: Color {
        if accentHex.hasPrefix("#"), let color = Color(hex: accentHex) { return color }
        return Color(red: 1.0, green: 0.28, blue: 0.36)
    }

    private var volumeColor: Color {
        if volumeHex.hasPrefix("#"), let color = Color(hex: volumeHex) { return color }
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

// MARK: - 进度条

private struct ReferenceScrubber: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var isSeeking = false

    private var totalDuration: Double {
        max(max(player.duration, player.currentTrack?.duration ?? 0), 1)
    }

    private var displayTime: Double {
        (scrubbing || isSeeking) ? scrubValue : clock.progress
    }

    var body: some View {
        let total = totalDuration
        let time = displayTime

        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let progress = CGFloat(min(max(time / total, 0), 1))
                let filledWidth = width * progress
                let trackH: CGFloat = scrubbing ? 15 : 7
                let bubbleX = max(-width / 2 + 31, min(width / 2 - 31, filledWidth - width / 2))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: trackH)

                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: max(0, filledWidth), height: trackH)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !scrubbing {
                                scrubValue = clock.progress
                            }
                            scrubbing = true
                            isSeeking = false
                            let ratio = min(max(value.location.x / max(width, 1), 0), 1)
                            scrubValue = ratio * total
                        }
                        .onEnded { _ in
                            player.seek(to: scrubValue)
                            scrubbing = false
                            isSeeking = true
                        }
                )
                .overlay(alignment: .top) {
                    if scrubbing {
                        Text(wellamTimeString(scrubValue))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: Capsule())
                            .offset(x: bubbleX, y: -30)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
            .frame(height: 30)
            .onChange(of: clock.progress) { newProgress in
                if isSeeking, abs(newProgress - scrubValue) < 0.3 {
                    isSeeking = false
                }
            }

            HStack {
                Text(wellamTimeString(time))
                Spacer()
                Text("-" + wellamTimeString(max(0, total - time)))
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: 420)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: scrubbing)
    }
}

// MARK: - 音量

private struct ReferenceVolumeControl: View {
    @EnvironmentObject private var player: PlayerService
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16, height: 20)

            GeometryReader { geo in
                let width = geo.size.width
                let fraction = isDragging ? dragValue : Double(player.volume)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 7)
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: width * CGFloat(fraction), height: 7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let val = Double(min(max(value.location.x / width, 0), 1))
                            dragValue = val
                            player.volume = Float(val)
                        }
                        .onEnded { value in
                            let val = Double(min(max(value.location.x / width, 0), 1))
                            dragValue = val
                            player.volume = Float(val)
                            isDragging = false
                        }
                )
            }
            .frame(height: 20)

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16, height: 20)
        }
        .frame(height: 20)
    }
}

// MARK: - 迷你歌词预览（沉浸模式样式）

private struct MiniLyricsPreview: View {
    let action: () -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor

    private var currentLines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = lyricsCursor.activeIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (_, current, next) = currentLines
        Button(action: action) {
            VStack(spacing: 8) {
                if current == nil && next == nil {
                    Text("暂无歌词")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.54))
                } else {
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current?.id)
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Text(line?.text.isEmpty == false ? line!.text : " ")
            .font(.system(size: emphasized ? 17 : 14, weight: emphasized ? .bold : .medium))
            .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .id(line?.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - QueueView

private struct QueueView: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss

    private var playbackModeIcon: String {
        if player.shuffleEnabled { return "shuffle" }
        switch player.repeatMode {
        case .one: return "repeat.1"
        case .all: return "repeat"
        case .off: return "repeat"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 拖动指示条
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 8)

            // 标题栏：标题 + 数量 + 循环播放 + 清空
            HStack(spacing: 8) {
                Text("播放队列")
                    .font(.system(size: 17, weight: .bold))
                Text("\(player.queue.count) 首")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    player.cyclePlaybackMode()
                } label: {
                    Image(systemName: playbackModeIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(player.shuffleEnabled ? Color.accentColor : .primary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    player.clearQueue()
                } label: {
                    Text("清空")
                        .font(.system(size: 15, weight: .medium))
                }
                .disabled(player.queue.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if player.queue.isEmpty {
                Spacer()
                EmptyStateView(icon: "music.note.list", title: "播放队列为空")
                Spacer()
            } else {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                        row(track, index: index)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                    .onDelete { offsets in
                        // 从大到小删除，避免索引漂移
                        for index in offsets.sorted(by: >) where player.queue.indices.contains(index) {
                            player.removeFromQueue(at: index)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func row(_ track: Track, index: Int) -> some View {
        let isCurrent = index == player.currentIndex
        HStack(spacing: 12) {
            CoverImage(url: URL(string: track.album.picUrl ?? ""), size: 46, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(track.artistNames)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(Formatters.duration(track.duration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            player.play(tracks: player.queue, source: .none, startAt: track)
            dismiss()
        }
    }
}

// MARK: - Sheet 辅助修饰器

/// 评论区 sheet：iOS 16.4+ 使用半屏 detents + 透明背景（CommentsView 自绘背景）。
private struct CommentsSheetDetents: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 16.4, *) {
                content
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.white)
            } else if #available(iOS 16.0, *) {
                content
                    .presentationDetents([.medium, .large])
            } else {
                content
            }
        }
    }
}

extension View {
    @ViewBuilder
    func presentationDetentsSafe() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium])
        } else {
            self
        }
    }
}

// MARK: - 音量弹窗（照搬沉浸模式）

private struct CompactVolumePopover: View {
    @EnvironmentObject private var player: PlayerService
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 16, weight: .medium))

            GeometryReader { geo in
                let height = geo.size.height
                let fraction = min(max(CGFloat(player.volume), 0), 1)
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.82))
                        .frame(height: height * fraction)
                }
                .frame(width: isDragging ? 12 : 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            updateVolume(at: value.location.y, height: height)
                        }
                        .onEnded { value in
                            updateVolume(at: value.location.y, height: height)
                            isDragging = false
                        }
                )
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
            }
            .frame(width: 32, height: 132)
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            .accessibilityAdjustableAction(adjustVolume)

            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottom) {
            Triangle()
                .fill(.white.opacity(0.18))
                .frame(width: 16, height: 8)
                .offset(y: 8)
        }
    }

    private func updateVolume(at location: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        player.volume = Float(min(max(1 - location / height, 0), 1))
    }

    private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
        let step: Float = 0.05
        switch direction {
        case .increment: player.volume = min(player.volume + step, 1)
        case .decrement: player.volume = max(player.volume - step, 0)
        @unknown default: break
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

// MARK: - 歌词偏移调整面板

struct LyricOffsetSheet: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss

    private var offsetText: String {
        if settings.lyricOffset == 0 { return "同步" }
        return settings.lyricOffset > 0
            ? "提前 \(String(format: "%.1f", settings.lyricOffset))s"
            : "延后 \(String(format: "%.1f", -settings.lyricOffset))s"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("歌词进度偏移")
                                .font(.system(size: 16, weight: .medium))
                            Spacer()
                            Text(offsetText)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                        Slider(
                            value: $settings.lyricOffset,
                            in: -10...10,
                            step: 0.1
                        )
                        .tint(.red)
                        Text("歌词与音频不同步时手动校正（正数提前、负数延后）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("重置") {
                                settings.lyricOffset = 0
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("歌词偏移")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetentsSafe()
    }
}
