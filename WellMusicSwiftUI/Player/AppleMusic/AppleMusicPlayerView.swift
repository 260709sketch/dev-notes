import SwiftUI
import MediaPlayer
import UIKit

// 说明：本文件为 **Kumone / wellam AppleMusic 播放器的 UI 与交互回迁**。
//
// 回迁边界（用户明确要求）：
//   ✅ 搬运：竖屏大封面 → 歌词页的封面/文本锚点插值动画、横屏左右分栏布局、
//           迷你歌词预览、常驻音量条、歌词拖拽手势（含底部控制区联动隐藏）、
//           睡眠定时菜单、播放器样式 Sheet、整体视觉与动效参数。
//   ❌ 不搬：进度条时间源（继续用 `PlayerCore.beginScrubbing/updateScrubbing/endScrubbing`）、
//           AMLL 歌词同步（继续用 `AMLLWebLyricsView` + `hardCalibrate` 通道）。
//           这两处是 WellMusicSwiftUI 自己修好的实现，明文规定不得替换为 Kumone 版本。

/// Apple Music 风格全屏播放页：封面模糊背景 + 大封面/歌词页切换 + 底部控制栏。
struct AppleMusicPlayerView: View {
    let onOpenDestination: (Destination) -> Void
    let onDismiss: () -> Void

    /// 底部安全区域间距（不用 GeometryReader，避免 fullScreenCover 动画过程中尺寸不正确）
    static var safeAreaBottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.bottom ?? 0
    }

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared

    @State private var showLyrics = false
    @State private var headerDragOffset: CGFloat = 0
    @State private var showQueue = false
    @State private var showComments = false
    @State private var showAddToPlaylist = false
    @State private var showLyricOffsetSheet = false
    @State private var showPlayerModeSheet = false
    @State private var showVolumePopover = false
    @State private var appleLayoutPart: AppleMusicLayoutPart = .cover
    @AppStorage("wellmusic.lyricOffset") private var lyricOffset = 0.0
    @AppStorage("wellmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage("wellmusic.player.swipeSwitchSong") private var swipeSwitchSong = true

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
        // 不用 GeometryReader，避免 fullScreenCover 动画过程中尺寸不正确导致播放器只展开一半
        let screenSize = UIScreen.main.bounds.size
        let isLandscape = screenSize.width > screenSize.height

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
        }
        .ignoresSafeArea()
        // 歌词页面可见时禁用播放器下滑关闭手势，避免和歌词滚动手势冲突
        .environment(\.allowsNowPlayingDismiss, !showLyrics)
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
                    ReferenceQueueView()
                        .environmentObject(player)
                        .presentationDetents([.medium, .large])
                        .presentationBackground(.ultraThinMaterial)
                } else {
                    ReferenceQueueView()
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
            .modifier(CommentsSheetDetents())
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let t = track {
                AddToPlaylistSheet(track: t)
            }
        }
        .sheet(isPresented: $showPlayerModeSheet) {
            PlayerModeSheet()
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

            // 播放器选择
            Button {
                showPlayerModeSheet = true
            } label: {
                Label("播放器样式", systemImage: "music.note.tv")
            }

            // 歌词偏移
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

            // 睡眠定时
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
            Color.clear.frame(height: ReferencePlaybackPresentationMetrics.headerTopSpacing)

            ZStack {
                coverPage(size: size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showLyrics ? 0 : 1)
                lyricsPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showLyrics ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 封面插值动画：在两个占位锚点之间移动同一个 CoverImage
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
                        .shadow(color: .black.opacity(showLyrics ? 0.26 : 0.46),
                                radius: showLyrics ? 9 : 36,
                                y: showLyrics ? 4 : 18)
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

            // 右侧：AMLL 歌词（如果开启了 AMLL）或普通歌词
            if settings.appleMusicUseAMLL {
                // AMLL 歌词：继续使用 WellMusicSwiftUI 自身的 AMLLWebLyricsView
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

            if settings.showLyricPreview {
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
            // 顶部小横条区域：只有在这里下滑才能关闭播放器（透明不可见）
            ZStack {
                Color.clear
                Capsule()
                    .fill(.clear)
                    .frame(width: 36, height: 5)
            }
            .frame(height: ScreenAdapter.h(30))
            .contentShape(Rectangle())
            .offset(y: showLyrics ? headerDragOffset : 0)
            .gesture(
                showLyrics ? DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if value.translation.height > 0 {
                            headerDragOffset = value.translation.height * 0.5
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 80 {
                            onDismiss()
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            headerDragOffset = 0
                        }
                    }
                : nil
            )

            lyricsHeader
                .padding(.horizontal, ScreenAdapter.w(24))
                .padding(.top, ScreenAdapter.h(85))
                .padding(.bottom, ScreenAdapter.h(10))

            if settings.appleMusicUseAMLL {
                // AMLL 已在底层渲染歌词，这里只保留头部，剩余空间透明
                Color.clear.frame(maxHeight: .infinity)
            } else if lyrics.isEmpty {
                emptyLyricsView
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: ScreenAdapter.h(26)) {
                            Color.clear.frame(height: max(ScreenAdapter.h(88), lyricsViewportHeight * 0.30))
                            ForEach(lyrics) { line in
                                lyricLine(line, isFocused: line.id == currentVisualLyricID)
                                    .id(line.id)
                                    .background {
                                        GeometryReader { rowGeometry in
                                            Color.clear.preference(
                                                key: ReferenceLyricCenterKey.self,
                                                value: [line.id: rowGeometry.frame(in: .named("referenceLyricsViewport")).midY]
                                            )
                                        }
                                    }
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
                                .onChange(of: viewport.size.height) { lyricsViewportHeight = $0 }
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
