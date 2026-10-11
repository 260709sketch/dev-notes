import SwiftUI
import MediaPlayer
import UIKit

// 说明：本文件是对参考源码 `WellMusicAppleMusicV2Player.tsx`（2694 行）的逐区块移植。
// 目标为「视觉 / 布局 / 交互」+「动画细节」全部一摸一样，因此：
//   * 所有尺寸、圆角、配色、字号取自 AppleMusicV2 常量表（一一对应 RN StyleSheet）；
//   * 所有 spring / timing 曲线取自 AppleMusicV2.Motion（一一对应 withSpring / withTiming 参数）；
//   * 结构对应用 RN 的 upperArea + BottomControls + EmbeddedPanels，不再用 sheet 弹面板。

/// Apple Music V2 风格全屏播放页。
///
/// 三个状态（与参考视频一致）：
/// 1. 主播放页：大封面 + 歌名/歌手/专辑 + 收藏/更多；
/// 2. 歌词页：封面缩到左上角迷你位、歌曲信息横移到右侧、大歌词铺满；
/// 3. 队列页：同上的迷你封面 + 歌曲信息 + 播放队列卡片。
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

    static var safeAreaTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.top ?? 47
    }

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    /// 播放模式 / 音质 / 歌词偏移等已迁到播放器菜单，需要观察 AppState 才能让勾选状态刷新
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var account = AccountStore.shared
    @ObservedObject private var clock = PlayerService.shared.clock
    @Environment(\.colorScheme) private var colorScheme

    // MARK: - 面板状态（对应 RN 的 showLyrics / showComments / showQueue）
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showComments = false
    /// `compactSongInfo`：歌词/队列模式下歌曲信息行切到绝对定位
    @State private var compactSongInfo = false

    // MARK: - 手动提交的 transion 参数（对应 coverScaleAnim / coverTranslateX/Y）
    /// 封面从大封面中心位移到左上角迷你位的像素偏移
    @State private var coverOffset: CGSize = .zero
    @State private var coverScale: CGFloat = 1
    /// 歌词/队列/评论容器淡入 + 上移（对应 modeOpacity / modeTranslateY）
    @State private var compactContentVisible = false
    /// 歌曲信息行透明度（对应 songInfoOpacity 的 120ms 淡出 → 180ms 淡入）
    @State private var songInfoOpacity: Double = 1

    // MARK: - 整页下滑关闭
    @State private var dismissDragOffset: CGFloat = 0
    @State private var dismissGestureActive = false

    // MARK: - 其他
    @State private var showAddToPlaylist = false
    @State private var showLyricOffsetSheet = false
    @State private var amllReady = false
    @State private var showFallbackBackground = true
    @StateObject private var dynamicCover = DynamicCoverManager()

    private var track: Track? { player.currentTrack }
    private var lyrics: [LyricLine] { player.lyrics?.lines ?? [] }
    private var coverURL: URL? {
        guard let pic = track?.album.picUrl else { return nil }
        return URL(string: pic)
    }

    // MARK: - Body

    var body: some View {
        // 不用 GeometryReader，避免 fullScreenCover 动画过程中尺寸不正确导致播放器只展开一半
        let screenSize = UIScreen.main.bounds.size

        ZStack {
            backgroundLayer

            content(screenSize: screenSize)
                // 顶部让出安全区 + `styles.artworkWrapper.marginTop: 40`，与 enterCompactMode 的
                // `coverInitY = top + 16 + 40 + artworkSize / 2` 保持一致。
                .padding(.top, Self.safeAreaTopInset + AppleMusicV2.Compact.coverInitTopBase)
                .offset(y: dismissDragOffset)
                .overlay(alignment: .top) {
                    Capsule(style: .continuous)
                        .fill(AppleMusicV2.HomeIndicator.color)
                        .frame(width: AppleMusicV2.HomeIndicator.width,
                               height: AppleMusicV2.HomeIndicator.height)
                        .padding(.top, AppleMusicV2.HomeIndicator.top)
                        .allowsHitTesting(false)
                }
        }
        .ignoresSafeArea()
        .onAppear {
            if settings.dynamicCoverEnabled { dynamicCover.updateTrack(track) }
        }
        .onChange(of: track?.id) { _ in
            if settings.dynamicCoverEnabled { dynamicCover.updateTrack(track) }
        }
        .onChange(of: settings.dynamicCoverEnabled) { enabled in
            if enabled { dynamicCover.updateTrack(track) } else { dynamicCover.clear() }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let t = track { AddToPlaylistSheet(track: t) }
        }
        .sheet(isPresented: $showLyricOffsetSheet) {
            LyricOffsetSheet()
        }
    }

    // MARK: - 内容区（对应 RN `styles.content` + `upperArea` + `BottomControls`）

    private func content(screenSize: CGSize) -> some View {
        VStack(spacing: 0) {
            // `styles.upperArea { flex: 1 }`
            ZStack(alignment: .top) {
                artworkAndInfo(screenSize: screenSize)

                // 队列页（对应 `showQueue && <Animated.View style={[styles.queueContent, compactContentAnimStyle]}>`，
                // `styles.queueContent { top: 70, bottom: 0, zIndex: 4 }`）
                if showQueue {
                    queuePanel()
                        .modifier(CompactContentTransition(visible: compactContentVisible))
                        .padding(.top, 70)
                }

                // 评论页：外壳同队列（参考源码复用 queueContent 样式）
                if showComments {
                    commentsPanel()
                        .modifier(CompactContentTransition(visible: compactContentVisible))
                        .padding(.top, 70)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomControls
        }
        .padding(.horizontal, AppleMusicV2.contentPadding)
        .padding(.bottom, Self.safeAreaBottomInset + 8)
        // 歌词页（非 AMLL 回退）：参考源码用 AMLL WebView 渲染歌词；
        // 关闭 AMLL 时用原生列表补位，位置按 `styles.lyricsArea { top: 236, bottom: 0 }`。
        .overlay(alignment: .topLeading) {
            if showLyrics && !settings.appleMusicUseAMLL {
                lyricsFallbackPage
                    .padding(.horizontal, AppleMusicV2.contentPadding)
                    .padding(.top, 236)
                    .modifier(CompactContentTransition(visible: compactContentVisible))
            }
        }
        // compact 歌曲信息行：与小封面垂直居中、绝对定位在封面右侧（对应 RN `position: 'absolute'`）
        .overlay(alignment: .topLeading) {
            if compactSongInfo {
                songInfoRow(miniArtworkSize: AppleMusicV2.Compact.artworkSize)
                    .padding(.horizontal, AppleMusicV2.contentPadding)
                    .padding(.top, Self.safeAreaTopInset
                             + AppleMusicV2.Compact.topOffset
                             + AppleMusicV2.Compact.artworkSize / 2
                             - AppleMusicV2.Title.compactTopAnchor)
            }
        }
    }

    // MARK: - 非 AMLL 歌词回退页

    private var lyricsFallbackPage: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 60)
                    ForEach(lyrics) { line in
                        Button {
                            WellHaptics.tap()
                            player.seek(to: LyricTiming.seekTime(for: line, userOffset: appState.lyricOffset))
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: line.id == activeLyricIndex ? 27 : 23,
                                                  weight: line.id == activeLyricIndex ? .bold : .semibold))
                                    .foregroundStyle(.white.opacity(line.id == activeLyricIndex ? 1 : 0.36))
                                    .fixedSize(horizontal: false, vertical: true)
                                if line.id == activeLyricIndex,
                                   let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.42))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .scaleEffect(line.id == activeLyricIndex ? 1.06 : 0.84, anchor: .leading)
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                    }
                    Color.clear.frame(height: 110)
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.84),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: activeLyricIndex) { index in
                guard let line = lyrics.first(where: { $0.id == index }) else { return }
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                    proxy.scrollTo(line.id, anchor: .center)
                }
            }
        }
    }

    /// 当前应高亮的歌词行 id（与进度条同源，含用户偏移）
    private var activeLyricIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        let progress = LyricTiming.effectiveProgress(clock.progress, userOffset: appState.lyricOffset)
        var answer: Int?
        for line in lyrics {
            if line.time <= progress { answer = line.id } else { break }
        }
        return answer ?? lyrics.first?.id
    }

    // MARK: - 大封面 + 歌曲信息（对应 RN artworkWrapper / songInfoRow）

    private func artworkAndInfo(screenSize: CGSize) -> some View {
        let artworkSize = screenSize.width * AppleMusicV2.artworkWidthRatio

        return VStack(spacing: 0) {
            // `styles.artworkWrapper { alignItems: center, marginTop: 40 }`
            ZStack {
                artworkImage(size: artworkSize)
                    // transform 顺序：translate 在前、scale 在后 —— scale 最后施加，
                    // translate 是绝对像素位移、不被缩放比例折算（与参考源码一致）
                    .offset(coverOffset)
                    .scaleEffect(coverScale)
                    // 动态圆角：`borderRadius: 24 / max(coverScaleAnim, 0.1)`，缩放时保持视觉圆角一致
                    .clipShape(RoundedRectangle(cornerRadius: AppleMusicV2.artworkCornerRadius / max(coverScale, 0.1),
                                                style: .continuous))
                    .shadow(color: .black.opacity(AppleMusicV2.artworkShadowOpacity * coverScale),
                            radius: AppleMusicV2.artworkShadowRadius * coverScale,
                            y: AppleMusicV2.artworkShadowY * coverScale)
                    // `artworkScale`：播放 1 / 暂停 0.85（`{damping:15, stiffness:100}`）
                    .scaleEffect(player.isPlaying ? 1 : 0.85)
                    .animation(AppleMusicV2.Motion.artworkSpring, value: player.isPlaying)
                    .animation(AppleMusicV2.Motion.compactSpring, value: coverScale)
                    .animation(AppleMusicV2.Motion.compactSpring, value: coverOffset)
                    .onTapGesture {
                        if showLyrics || showQueue || showComments {
                            hideCompactMode()
                        } else {
                            showLyricsMode()
                        }
                    }
            }
            .frame(height: artworkSize)
            .frame(maxWidth: .infinity)

            // `songInfoRowSpacer { flex: 1 }` ×2：让信息行在大封面与进度条之间垂直居中
            Spacer(minLength: 0)

            if !compactSongInfo {
                songInfoRow(miniArtworkSize: AppleMusicV2.Compact.artworkSize)
            }

            Spacer(minLength: 0)
        }
        // 大封面页整页接管下滑关闭（歌词/队列/评论页由各自内部滚动区处理）
        .contentShape(Rectangle())
        .gesture(isCompactActive ? nil : swipeToDismissGesture(screenHeight: screenSize.height))
    }

    @ViewBuilder
    private func artworkImage(size: CGFloat) -> some View {
        ZStack {
            CoverImage(
                url: coverURL,
                size: size,
                cornerRadius: AppleMusicV2.artworkCornerRadius,
                emptyHint: player.isBuffering ? "等待开始播放…" : nil
            )

            // 网易云动态封面：有 videoPlayUrl 时静音循环播放覆盖静态封面
            if settings.dynamicCoverEnabled, let dynamicURL = dynamicCover.coverURL {
                DynamicCoverPlayer(url: dynamicURL)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: AppleMusicV2.artworkCornerRadius / max(coverScale, 0.1),
                                                style: .continuous))
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
    }

    /// `styles.songInfoRow`
    ///
    /// - 大封面态：正常流式布局，居中，`maxWidth` 按参考源码的 72% / 58% 切换；
    /// - compact 态：由调用方放进 `.overlay(alignment: .topLeading)` 做绝对定位，
    ///   左侧让出 `miniArtworkSize + 8`，整行水平铺满、两端对齐。
    private func songInfoRow(miniArtworkSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            songInfoLeft
                .frame(maxWidth: showLyrics ? 205 : 260, alignment: .leading)
                .padding(.trailing, AppleMusicV2.Title.leftPaddingRight)

            Spacer(minLength: 0)

            songInfoRight
        }
        .padding(.leading, compactSongInfo ? miniArtworkSize + AppleMusicV2.Title.compactLeftGap : 0)
        .padding(.trailing, compactSongInfo ? AppleMusicV2.Title.compactRight : 0)
        .opacity(songInfoOpacity)
    }

    private var songInfoLeft: some View {
        VStack(alignment: .leading, spacing: AppleMusicV2.Title.metaSpacing) {
            // `styles.songTitleClip { overflow: hidden }` —— 长标题跑马灯
            MarqueeText(
                text: track?.name ?? "未在播放",
                font: .system(size: AppleMusicV2.Title.fontSize, weight: .semibold),
                color: .white
            )

            HStack(spacing: 0) {
                artistText
                Text(" — ")
                    .font(.system(size: AppleMusicV2.Title.metaFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Text(albumText)
                    .font(.system(size: AppleMusicV2.Title.metaFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .lineLimit(1)
        }
    }

    /// 歌手：多歌手时给出选择菜单（对应参考源码 MenuView「选择歌手」）
    @ViewBuilder
    private var artistText: some View {
        let raw = track?.artistNames ?? "未知歌手"
        // 大封面状态最多 24 字，歌词界面最多 17 字（对应参考源码 maxLen）
        let maxLen = showLyrics ? 17 : 24
        let display = raw.count > maxLen ? String(raw.prefix(maxLen)) + ".." : raw
        let names = splitArtists(raw)

        if names.count <= 1 {
            Text(display)
                .font(.system(size: AppleMusicV2.Title.metaFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .onTapGesture { openArtist(names.first) }
        } else {
            Menu {
                ForEach(names, id: \.self) { name in
                    Button {
                        openArtist(name)
                    } label: {
                        Label(name, systemImage: "person.crop.circle")
                    }
                }
            } label: {
                Text(display)
                    .font(.system(size: AppleMusicV2.Title.metaFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        }
    }

    private var albumText: String {
        let name = track?.album.name ?? ""
        return name.isEmpty ? "未知专辑" : name
    }

    private var songInfoRight: some View {
        HStack(spacing: 0) {
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: AppleMusicV2.Title.headerIconSize, weight: .regular))
                    .foregroundStyle(.white)
                    .padding(AppleMusicV2.Title.headerIconPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            moreMenu
        }
        .padding(.leading, AppleMusicV2.Title.rightMarginLeft)
    }

    // MARK: - 底部控制栏（对应 RN BottomControls）

    private var bottomControls: some View {
        VStack(spacing: 0) {
            AppleMusicV2ProgressSection()
                .padding(.bottom, AppleMusicV2.Controls.progressSectionBottom)

            // `styles.playControlsRow { justifyContent: space-around }`
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: AppleMusicV2.Controls.controlIconSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(AppleMusicV2.Controls.controlPadding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                playButton

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: AppleMusicV2.Controls.controlIconSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(AppleMusicV2.Controls.controlPadding)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.top, AppleMusicV2.Controls.playRowMarginTop)

            AppleMusicV2VolumeRow()
                .padding(.top, AppleMusicV2.Controls.volumeRowTop)

            bottomButtonsRow
                .padding(.top, AppleMusicV2.Controls.bottomButtonsTop)
        }
        .padding(.top, AppleMusicV2.Controls.topMargin)
    }

    /// `styles.playButton` 88×88 + 圆形按压高亮 + 播放/暂停图标交叉过渡
    private var playButton: some View {
        Button {
            triggerPlayPress()
            player.togglePlayPause()
        } label: {
            ZStack {
                // `styles.playPressCircle`：点击时淡入、350ms out(quad) 过渡消失
                Circle()
                    .fill(AppleMusicV2.Controls.playPressCircleColor)
                    .frame(width: AppleMusicV2.Controls.playPressCircleSize,
                           height: AppleMusicV2.Controls.playPressCircleSize)
                    .opacity(playPressOpacity)

                // 暂停图标： opacity withTiming(isPlaying ? 1 : 0, 180ms)、scale withTiming(isPlaying ? 1 : 0.6, 180ms)
                Image(systemName: "pause.fill")
                    .font(.system(size: AppleMusicV2.Controls.controlIconSize, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(player.isPlaying ? 1 : 0)
                    .scaleEffect(player.isPlaying ? 1 : 0.6)
                    .animation(AppleMusicV2.Motion.playIconCrossfade, value: player.isPlaying)

                // 播放图标： opacity withTiming(isPlaying ? 0 : 1, 180ms)、scale withTiming(isPlaying ? 0.6 : 1, 180ms)
                Image(systemName: "play.fill")
                    .font(.system(size: AppleMusicV2.Controls.controlIconSize, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(player.isPlaying ? 0 : 1)
                    .scaleEffect(player.isPlaying ? 0.6 : 1)
                    .animation(AppleMusicV2.Motion.playIconCrossfade, value: player.isPlaying)
            }
            .frame(width: AppleMusicV2.Controls.playButtonSize,
                   height: AppleMusicV2.Controls.playButtonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @State private var playPressOpacity: Double = 0

    /// `triggerPlayPress()`：`playPressAnim = 1` 然后 350ms out(quad) 归零
    private func triggerPlayPress() {
        // 立即拉到 1（无动画），再 out(quad) 350ms 淡出 —— 对应 RN 里先赋值再 withTiming(0)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { playPressOpacity = 1 }
        withAnimation(AppleMusicV2.Motion.playPressFade) {
            playPressOpacity = 0
        }
    }

    /// `styles.bottomButtonsRow`：歌词 / AirPlay / 评论 / 队列（队列右上角带播放模式角标）
    private var bottomButtonsRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            bottomButton(icon: showLyrics ? "quote.bubble.fill" : "quote.bubble",
                         active: showLyrics) {
                showLyrics ? hideCompactMode() : showLyricsMode()
            }

            // AirPlay 路由按钮：原生 MPVolumeView，点击弹出系统 AirPlay 设备面板
            AirPlayRouteButton()
                .frame(width: AppleMusicV2.Controls.bottomButtonIconSize + AppleMusicV2.Controls.bottomButtonPadding * 2,
                       height: AppleMusicV2.Controls.bottomButtonIconSize + AppleMusicV2.Controls.bottomButtonPadding * 2)
                .padding(AppleMusicV2.Controls.bottomButtonPadding)

            bottomButton(icon: showComments ? "text.bubble.fill" : "text.bubble",
                         active: showComments) {
                showComments ? hideCompactMode() : showCommentsMode()
            }

            bottomButton(icon: "list.bullet", active: showQueue) {
                showQueue ? hideCompactMode() : showQueueMode()
            } badge: {
                queueModeBadge
            }

            Spacer(minLength: 0)
        }
    }

    private func bottomButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        bottomButton(icon: icon, active: active, action: action) { EmptyView() }
    }

    private func bottomButton<Badge: View>(
        icon: String,
        active: Bool,
        action: @escaping () -> Void,
        @ViewBuilder badge: () -> Badge
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: AppleMusicV2.Controls.bottomButtonIconSize, weight: .medium))
                .foregroundStyle(active ? .white : AppleMusicV2.Controls.bottomButtonIconColor)
                .padding(AppleMusicV2.Controls.bottomButtonPadding)
                .background(
                    RoundedRectangle(cornerRadius: AppleMusicV2.Controls.bottomButtonRadius, style: .continuous)
                        .fill(active ? AppleMusicV2.Controls.bottomButtonHighlight : .clear)
                )
                .overlay(alignment: .topTrailing) { badge() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `styles.queueModeBadge`：18×18 毛玻璃圆点 + 半透明白描边 + 播放模式图标
    private var queueModeBadge: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(Color.white.opacity(0.25)))
            Image(systemName: playbackModeIcon)
                .font(.system(size: AppleMusicV2.Controls.queueBadgeIconSize, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: AppleMusicV2.Controls.queueBadgeSize,
               height: AppleMusicV2.Controls.queueBadgeSize)
        .overlay(
            Circle().strokeBorder(AppleMusicV2.Controls.queueBadgeBorder, lineWidth: 0.5)
        )
        .offset(x: AppleMusicV2.Controls.queueBadgeOffset,
                y: AppleMusicV2.Controls.queueBadgeOffset)
        .allowsHitTesting(false)
    }

    // MARK: - 队列面板（对应 RN EmbeddedPanels 面板 3 / PlaylistQueue amStyle）

    private func queuePanel() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("播放队列 · \(player.queue.count)")
                .font(.system(size: AppleMusicV2.Queue.titleFontSize, weight: .medium))
                .tracking(AppleMusicV2.Queue.titleTracking)
                .foregroundStyle(.white)

            queueModeSegment
                .padding(.top, AppleMusicV2.Queue.segmentBottom)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: AppleMusicV2.Queue.rowSpacing) {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { _, item in
                        queueRow(item)
                    }
                    Color.clear.frame(height: AppleMusicV2.Queue.listPaddingBottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 6)
    }

    /// `styles.queueModeSegment`：顺序 / 随机 / 单曲
    private var queueModeSegment: some View {
        HStack(spacing: 0) {
            segmentItem(icon: "repeat", title: "顺序", mode: 0)
            segmentItem(icon: "shuffle", title: "随机", mode: 2)
            segmentItem(icon: "repeat.1", title: "单曲", mode: 1, showsDivider: false)
        }
        .frame(height: AppleMusicV2.Queue.segmentHeight)
        .background(AppleMusicV2.Queue.segmentFill)
        .clipShape(RoundedRectangle(cornerRadius: AppleMusicV2.Queue.segmentRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppleMusicV2.Queue.segmentRadius, style: .continuous)
                .strokeBorder(AppleMusicV2.Queue.segmentBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func segmentItem(icon: String, title: String, mode: Int, showsDivider: Bool = true) -> some View {
        let active = appState.playMode == mode
        Button {
            appState.playMode = mode
        } label: {
            HStack(spacing: AppleMusicV2.Queue.segmentGap) {
                Image(systemName: icon)
                    .font(.system(size: active ? 20 : 19))
                    .foregroundStyle(active ? .white : .white.opacity(0.7))
                Text(title)
                    .font(.system(size: AppleMusicV2.Queue.segmentTextSize, weight: .medium))
                    .foregroundStyle(AppleMusicV2.Queue.segmentTextColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(active ? AppleMusicV2.Queue.segmentItemActiveFill : .clear)
            .overlay(alignment: .trailing) {
                if showsDivider {
                    Rectangle()
                        .fill(AppleMusicV2.Queue.segmentItemDivider)
                        .frame(width: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `styles.queueItem`：44/48 封面 + 歌名歌手 + 当前播放喇叭 + 删除
    private func queueRow(_ item: Track) -> some View {
        let isCurrent = item.id == track?.id
        return HStack(spacing: AppleMusicV2.Queue.rowGap) {
            CoverImage(url: URL(string: item.album.picUrl ?? ""),
                       size: AppleMusicV2.Queue.rowArtworkSize,
                       cornerRadius: AppleMusicV2.Queue.rowArtworkRadius)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: AppleMusicV2.Queue.rowTitleSize, weight: .medium))
                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.artistNames)
                    .font(.system(size: AppleMusicV2.Queue.rowArtistSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent {
                Image(systemName: "speaker.wave.3")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.8))
            }

            Button {
                if let index = player.queue.firstIndex(where: { $0.id == item.id }) {
                    player.removeFromQueue(at: index)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: AppleMusicV2.Queue.rowTrailingWidth,
                           height: AppleMusicV2.Queue.rowTrailingHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppleMusicV2.Queue.rowHPadding)
        .padding(.vertical, AppleMusicV2.Queue.rowVPadding)
        .background(isCurrent ? AppleMusicV2.Queue.rowActiveFill : AppleMusicV2.Queue.rowFill,
                    in: RoundedRectangle(cornerRadius: AppleMusicV2.Queue.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { play(item) }
    }

    // MARK: - 评论面板（外壳同队列，参考源码复用 queueContent）

    private func commentsPanel() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.7))
                Text("评论")
                    .font(.system(size: AppleMusicV2.Queue.titleFontSize, weight: .medium))
                    .tracking(AppleMusicV2.Queue.titleTracking)
                    .foregroundStyle(.white)
            }

            ScrollView(showsIndicators: false) {
                if let t = track {
                    CommentsView(track: t)
                }
                Color.clear.frame(height: AppleMusicV2.Queue.listPaddingBottom)
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 6)
    }

    // MARK: - 面板切换（对应 handleShowLyrics / handleShowQueue / handleShowComments / handleHideCompactMode）

    /// 已处于任意 compact 面板时切换只换内容，不重跑封面/歌曲信息动画，避免顶部信息闪烁
    private func showLyricsMode() {
        if !isCompactActive { enterCompactMode() }
        showQueue = false
        showComments = false
        showLyrics = true
    }

    private func showQueueMode() {
        if !isCompactActive { enterCompactMode() }
        showLyrics = false
        showComments = false
        showQueue = true
    }

    private func showCommentsMode() {
        if !isCompactActive { enterCompactMode() }
        showLyrics = false
        showQueue = false
        showComments = true
    }

    private var isCompactActive: Bool { showLyrics || showQueue || showComments }

    /// `enterCompactMode()`：封面缩到左上角迷你位、歌曲信息横移、内容淡入上移
    private func enterCompactMode() {
        let screen = UIScreen.main.bounds.size
        let top = Self.safeAreaTopInset
        let artworkSize = screen.width * AppleMusicV2.artworkWidthRatio
        let miniSize = AppleMusicV2.Compact.artworkSize
        let miniScale = miniSize / artworkSize

        // 封面初始中心：内容区水平居中、垂直 = top + 16 + 40 + 封面一半
        let coverInitX = screen.width / 2
        let coverInitY = top + AppleMusicV2.Compact.coverInitTopBase + artworkSize / 2
        // 封面目标：左上角迷你位（左 24、顶 top+14）
        let destLeft = AppleMusicV2.Compact.destLeft
        let destTop = top + AppleMusicV2.Compact.topOffset
        let tx = destLeft + miniSize / 2 - coverInitX
        let ty = destTop + miniSize / 2 - coverInitY

        // 封面：spring `{damping: 30, stiffness: 220, mass: 1}`
        withAnimation(AppleMusicV2.Motion.compactSpring) {
            coverScale = miniScale
            coverOffset = CGSize(width: tx, height: ty)
        }

        // 歌曲信息：淡出 120ms → 切换布局 → 淡入 180ms
        withAnimation(AppleMusicV2.Motion.songInfoFadeOut) { songInfoOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            compactSongInfo = true
            withAnimation(AppleMusicV2.Motion.songInfoFadeIn) { songInfoOpacity = 1 }
        }

        // 歌词/队列/评论容器：opacity 0→1、translateY 22→0，320ms inOut
        compactContentVisible = false
        DispatchQueue.main.async {
            withAnimation(AppleMusicV2.Motion.compactContentIn) {
                compactContentVisible = true
            }
        }
    }

    /// `handleHideCompactMode()`：与进入对称
    private func hideCompactMode() {
        // 封面 spring 回放大，自然回弹
        withAnimation(AppleMusicV2.Motion.compactSpring) {
            coverScale = 1
            coverOffset = .zero
        }
        // 歌词/队列立即隐藏，避免封面放大过程中与下方面板叠加闪烁
        showLyrics = false
        showQueue = false
        showComments = false

        // 歌曲信息：淡出 → 切回原位 → 淡入
        withAnimation(AppleMusicV2.Motion.songInfoFadeOut) { songInfoOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            compactSongInfo = false
            withAnimation(AppleMusicV2.Motion.songInfoFadeIn) { songInfoOpacity = 1 }
        }

        withAnimation(AppleMusicV2.Motion.compactSpring) {
            compactContentVisible = false
        }
    }

    // MARK: - 整页下滑关闭
    //
    // 大封面页没有内部滚动视图，可以整页接管下滑关闭（网易云同款手感）：
    // - 只接管「纵向 + 向下」的拉拽，位移超过 10pt 且纵向比横向明显时才启动；
    // - 跟手位移带阻尼（0.45），松手时超过屏高 18% 即关闭，否则弹回；
    // - 关闭时先用 0.28s 把页面推下去再调 onDismiss，避免露出生硬的转场。
    private func swipeToDismissGesture(screenHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let dy = value.translation.height
                let dx = value.translation.width
                if !dismissGestureActive {
                    guard dy > 10, abs(dy) > abs(dx) * 1.2 else { return }
                    dismissGestureActive = true
                }
                dismissDragOffset = max(0, dy) * 0.45
            }
            .onEnded { value in
                guard dismissGestureActive else { return }
                dismissGestureActive = false
                let shouldDismiss = value.translation.height > screenHeight * 0.18
                    || value.predictedEndTranslation.height > screenHeight * 0.35
                if shouldDismiss {
                    withAnimation(.easeIn(duration: 0.28)) {
                        dismissDragOffset = screenHeight
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        onDismiss()
                        dismissDragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        dismissDragOffset = 0
                    }
                }
            }
    }

    // MARK: - 背景
    //
    // 参考源码 `bgScale/bgTranslateX/bgTranslateY` 慢速流动 + AMLL 流动背景。
    // SwiftUI 侧沿用项目已实现的 CoverBlurView（模糊封面 + 呼吸缩放 + 渐变色缓慢摆动），
    // 参数已按参考源码对齐（AppleMusicV2.Motion.Background）。

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            Color.black

            CoverBlurBackground(url: coverURL, scheme: colorScheme)
                .overlay(Color.black.opacity(0.48))

            // AMLL 歌词页（背景流动 + 歌词一体）。
            // 参考源码 `amllShowLyrics = showLyrics && !showQueue`：队列/评论页隐藏歌词但保留流动背景。
            if settings.appleMusicUseAMLL && showLyrics {
                AMLLWebLyricsView(useAppleMusicSettings: true)
                    .padding(.top, ScreenAdapter.h(CGFloat(settings.appleMusicAmllLyricTop)))
                    .padding(.bottom, ScreenAdapter.h(CGFloat(settings.appleMusicAmllLyricBottom)))
                    .padding(.horizontal, ScreenAdapter.w(CGFloat(settings.appleMusicAmllLyricHorizontal)))
                    .opacity(amllReady ? 1 : 0)
                    .onAppear {
                        // 兜底超时：极端情况下页面未发送 ready 消息，3 秒后也强制就绪
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { amllReady = true }
                    }
            }

            // 静态模糊封面兜底：AMLL WebView 首次初始化（约 3 秒）期间盖住黑屏/loading，
            // 就绪后延迟 400ms 再 600ms 淡出露出流动背景，用户感觉不到等待。
            if showFallbackBackground && settings.appleMusicUseAMLL && showLyrics {
                CoverImage(url: coverURL, size: 1, cornerRadius: 0)
                    .hidden()
                    .overlay { Color.black.opacity(0.45) }
                    .transition(.opacity)
            }
        }
        .onChange(of: amllReady) { ready in
            guard ready, showFallbackBackground else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeOut(duration: AppleMusicV2.Motion.fallbackBgFade)) {
                    showFallbackBackground = false
                }
            }
        }
    }

    // MARK: - 衍生数据

    private var isFavorite: Bool { account.isLiked(track: track ?? placeholderTrack) }

    private func toggleFavorite() {
        guard let t = track else { return }
        Task { await AccountStore.shared.toggleLike(trackID: t.id, track: t) }
    }

    private var playbackModeIcon: String {
        switch appState.playMode {
        case 2: return "shuffle"
        case 1: return "repeat.1"
        default: return "repeat"
        }
    }

    private func play(_ item: Track) {
        player.play(tracks: player.queue, source: .none, startAt: item)
    }

    private func splitArtists(_ raw: String) -> [String] {
        raw.split(whereSeparator: { "/、,&".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func openArtist(_ name: String?) {
        guard let name, !name.contains("未知") else { return }
        let matched = track?.artists.first { $0.name == name } ?? track?.artists.first
        guard let artist = matched else { return }
        let summary = ArtistSummary(id: artist.id,
                                    name: artist.name,
                                    picUrl: nil,
                                    sourcePlatform: track?.sourcePlatform,
                                    singerMid: artist.singerMid)
        if let mid = artist.singerMid {
            onOpenDestination(.artistWithMid(artist.id, mid, summary))
        } else {
            onOpenDestination(.artist(artist.id))
        }
    }

    private var placeholderTrack: Track {
        Track(id: -1,
              name: "",
              artistNames: "",
              artists: [],
              album: Album(id: -1, name: "", picUrl: nil, albumMid: nil),
              duration: 0,
              sourcePlatform: nil,
              fee: 0,
              platformSongId: nil)
    }

    // MARK: - 三点菜单（对应 RN `menuActions` + `handleMenuPress`）

    @ViewBuilder
    private var moreMenu: some View {
        Menu {
            Button {
                openAlbum()
            } label: {
                Label("查看专辑", systemImage: "square.stack")
            }

            Button {
                showCommentsMode()
            } label: {
                Label("评论", systemImage: "text.bubble")
            }

            Button {
                shareSong()
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }

            Button {
                showAddToPlaylist = true
            } label: {
                Label("添加至歌单", systemImage: "folder.badge.plus")
            }

            Divider()

            // `lyricDelay` 子菜单：-3.0 → +3.0 秒
            Menu {
                ForEach([-3.0, -2.0, -1.0, -0.5, -0.2, 0, 0.2, 0.5, 1.0, 2.0, 3.0], id: \.self) { value in
                    Button {
                        applyLyricDelay(value)
                    } label: {
                        if abs(appState.lyricOffset - value) < 0.01 {
                            Label(delayTitle(value), systemImage: "checkmark")
                        } else {
                            Text(delayTitle(value))
                        }
                    }
                }
            } label: {
                Label(lyricDelayLabel, systemImage: "clock")
            }

            // 播放模式（自设置页迁到播放器界面）
            Menu {
                Button { appState.playMode = 0 } label: { modeLabel("顺序播放", 0) }
                Button { appState.playMode = 2 } label: { modeLabel("随机播放", 2) }
                Button { appState.playMode = 1 } label: { modeLabel("单曲循环", 1) }
            } label: {
                Label("播放模式", systemImage: "repeat")
            }

            Button {
                showLyricOffsetSheet = true
            } label: {
                Label("歌词偏移", systemImage: "timer")
            }

            Divider()

            // 睡眠定时
            Menu {
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) 分钟") {
                        player.sleepTimer.schedule(afterMinutes: minutes)
                    }
                    .disabled(!player.hasCurrentTrack)
                }
                Button {
                    player.sleepTimer.scheduleAtEndOfCurrentTrack()
                } label: {
                    Label("当前歌曲播放完", systemImage: "music.note")
                }
                .disabled(!player.hasCurrentTrack)
                if player.sleepTimer.state.isActive {
                    Divider()
                    Button("关闭定时器", role: .destructive) {
                        player.sleepTimer.cancel()
                    }
                }
            } label: {
                Label(player.sleepTimer.state.isActive ? "睡眠定时（进行中）" : "睡眠定时",
                      systemImage: "timer")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: AppleMusicV2.Title.headerIconSize, weight: .regular))
                .foregroundStyle(.white)
                .padding(AppleMusicV2.Title.headerIconPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func modeLabel(_ title: String, _ mode: Int) -> some View {
        if appState.playMode == mode {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var lyricDelayLabel: String {
        let value = appState.lyricOffset
        guard value != 0 else { return "歌词时间微调" }
        let direction = value > 0 ? "提前" : "推迟"
        let abs = Swift.abs(value)
        let text = abs.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", abs)
            : String(format: "%.1f", abs)
        return "歌词时间微调（当前\(value > 0 ? "+" : "")\(text)秒\(direction)）"
    }

    private func delayTitle(_ value: Double) -> String {
        if value == 0 { return "复位（0.0秒）" }
        let abs = Swift.abs(value)
        let text = abs.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.1f", abs)
            : String(format: "%.1f", abs)
        if value < 0 { return "-\(text)秒（歌词推迟）" }
        if value > 0 { return "+\(text)秒（歌词提前）" }
        return "\(text)秒"
    }

    private func applyLyricDelay(_ value: Double) {
        appState.lyricOffset = value
        settings.lyricOffset = value
        if value == 0 {
            ToastCenter.shared.show("歌词时间已复位")
        } else {
            let direction = value > 0 ? "前" : "后"
            ToastCenter.shared.show("歌词移到 \(String(format: "%.1f", Swift.abs(value))) 秒\(direction)")
        }
    }

    private func openAlbum() {
        guard let t = track else { return }
        let summary = AlbumSummary(id: t.album.id,
                                   name: t.album.name,
                                   picUrl: t.album.picUrl,
                                   sourcePlatform: t.sourcePlatform,
                                   albumMid: t.album.albumMid)
        if let mid = t.album.albumMid {
            onOpenDestination(.albumWithMid(t.album.id, mid, summary))
        } else {
            onOpenDestination(.album(t.album.id))
        }
    }

    private func shareSong() {
        guard let t = track else { return }
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
}

// MARK: - 内容淡入 + 上移（对应 RN `compactContentAnimStyle`）

private struct CompactContentTransition: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 22)
    }
}

// MARK: - 跑马灯（对应 RN `marqueeAnim` + `styles.songTitleClip`）
//
// 歌名超出容器宽度时横向循环滚动：滚动到尾部停顿，再回到起点。
// 参考源码用 reanimated 的 `withRepeat(withSequence(withTiming(...), withDelay(...)), -1, false)`。

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    var body: some View {
        // 用隐藏的完整文本量出真实宽度，容器宽度决定是否需要滚动
        ZStack(alignment: .leading) {
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .background(
                    GeometryReader { textGeo in
                        Color.clear
                            .onAppear { textWidth = textGeo.size.width }
                            .onChange(of: text) { _ in textWidth = textGeo.size.width }
                            .onChange(of: textGeo.size.width) { newValue in textWidth = newValue }
                    }
                )

            GeometryReader { geo in
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: offset)
                    .onAppear { containerWidth = geo.size.width; restart() }
                    .onChange(of: geo.size.width) { newValue in
                        containerWidth = newValue
                        restart()
                    }
                    .onChange(of: text) { _ in restart() }
            }
            .clipped()
        }
    }

    private func restart() {
        offset = 0
        guard overflow > 1 else { return }
        let duration = Double(overflow) / Double(AppleMusicV2.Motion.Marquee.pointsPerSecond)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [overflow, duration] in
            guard overflow > 1 else { return }
            withAnimation(.linear(duration: duration)) { offset = -overflow }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + AppleMusicV2.Motion.Marquee.pause) {
                withAnimation(.linear(duration: 0.4)) { offset = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + AppleMusicV2.Motion.Marquee.pause) {
                    restart()
                }
            }
        }
    }
}
