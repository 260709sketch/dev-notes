import SwiftUI

// MARK: - WellMusicAppleMusicV2Player 视觉常量
//
// 严格照搬参考源码 `WellMusicAppleMusicV2Player.tsx` 的 StyleSheet。
// 所有数值均取自 RN 源码，单位即为 pt；屏幕基准 iPhone 14 Pro (393×852)。
// 需要随屏幕缩放的少量尺寸走 ScreenAdapter，其余按参考源码写死以保证「一摸一样」。

enum AppleMusicV2 {
    // MARK: 布局

    /// `styles.content.paddingHorizontal: 24`
    static let contentPadding: CGFloat = 24
    /// `styles.artworkWrapper.marginTop: 40`
    static let artworkWrapperTop: CGFloat = 40
    /// `styles.albumArtwork.width/height = SCREEN_WIDTH * 0.86`
    static let artworkWidthRatio: CGFloat = 0.86
    /// `styles.albumArtwork.borderRadius: 24`
    static let artworkCornerRadius: CGFloat = 24
    /// 小封面圆角（参考 `miniArtworkSize` 落点：圆角 12）
    static let miniArtworkCornerRadius: CGFloat = 12

    /// 封面「视觉圆角」随缩放插值的两端值。
    ///
    /// 参考源码 `albumArtRoundStyle`：
    /// ```js
    /// const target = 24 - (1 - sc) / (1 - miniArtworkScale) * 12
    /// return { borderRadius: target / sc }   // RN 的 borderRadius 会被 transform scale 折算
    /// ```
    /// 即 **视觉圆角** `= target`：大封面 `sc = 1` → 24；小封面 `sc = miniScale` → 12。
    /// Apple Music 的小封面明显更圆，这个渐变是它的标志性细节，不能简化为恒定圆角。
    enum ArtworkRadius {
        /// 大封面视觉圆角（= `artworkCornerRadius`）
        static let large: CGFloat = 24
        /// 小封面视觉圆角
        static let mini: CGFloat = 12

        /// 按当前缩放比例换算「形状圆角」（供 SwiftUI `RoundedRectangle` 使用）。
        ///
        /// SwiftUI 与 RN 的折算方式不同：
        /// - RN 的 `borderRadius` 会被 `transform: scale` **反比折算**，所以源码要 `target / sc`；
        /// - SwiftUI 的 `scaleEffect` 同样会缩放形状圆角，`clipShape` 的 `cornerRadius` 也要 `target / sc`
        ///   才能让**视觉**圆角落在上式的 `target` 上。
        ///
        /// - Parameter scale: 当前 `coverScale`（1 = 大封面，`miniScale` = 左上角迷你位）
        /// - Parameter miniScale: 迷你位缩放比 `miniArtworkSize / mainArtworkSize`
        static func shapeRadius(forScale scale: CGFloat, miniScale: CGFloat) -> CGFloat {
            let sc = max(scale, 0.1)
            // miniScale 逼近 1 时上式除零：此时大/小封面同尺寸，直接退回大圆角
            guard miniScale < 0.999 else { return large / sc }
            let target = large - (1 - sc) / (1 - miniScale) * (large - mini)
            return target / sc
        }
    }
    /// `styles.albumArtwork.shadowOffset {width:0,height:18} / shadowOpacity 0.5 / shadowRadius 32`
    static let artworkShadowRadius: CGFloat = 32
    static let artworkShadowY: CGFloat = 18
    static let artworkShadowOpacity: Double = 0.5

    /// `enterCompactMode()` 落点
    enum Compact {
        static let destLeft: CGFloat = 24
        static let topOffset: CGFloat = 14
        /// `layoutSettings.lyricMiniArtworkSize ?? 80`
        static let artworkSize: CGFloat = 80
        /// 封面初始中心 Y = top + 16 + 40 + W*0.43（见 enterCompactMode 注释）
        static let coverInitTopBase: CGFloat = 16 + 40
        /// 内容区顶部的纯安全区留白：`content { paddingTop: top + 16 }`。
        ///
        /// ⚠️ 参考源码里 `artworkWrapper.marginTop: 40` 是 **upperArea 内部** 的间距，
        /// 不属于 content 的 paddingTop。SwiftUI 侧必须保持同样的层级关系，
        /// 否则 `upperArea` 的坐标原点会上移 40pt，令 compact 歌曲信息行的绝对定位整体偏移。
        static let contentTopInset: CGFloat = 16
        /// 封面容器上边距：`styles.artworkWrapper { marginTop: 40 }`（upperArea 内部）
        static let artworkWrapperMarginTop: CGFloat = 40
    }

    /// `styles.topHomeIndicator`
    enum HomeIndicator {
        static let top: CGFloat = 60
        static let width: CGFloat = 45
        static let height: CGFloat = 5
        static let radius: CGFloat = 2.5
        static let color = Color.white.opacity(0.35)
    }

    // MARK: 标题 / 副标题

    enum Title {
        /// `styles.songTitle.fontSize: 18 / fontWeight '600'`
        static let fontSize: CGFloat = 18
        /// `styles.songArtist.fontSize: 14 / fontWeight '500'`
        static let metaFontSize: CGFloat = 14
        /// `styles.songMetaRow.marginTop: 4`
        static let metaSpacing: CGFloat = 4
        /// `styles.songInfoLeft.paddingRight: 8`
        static let leftPaddingRight: CGFloat = 8
        /// `styles.songInfoRight.marginLeft: 12`
        static let rightMarginLeft: CGFloat = 12
        /// compact 时 `left: miniArtworkSize + 8`
        static let compactLeftGap: CGFloat = 8
        /// compact 时 `top: miniArtworkSize / 2 - 18`
        static let compactTopAnchor: CGFloat = 18
        /// compact 时 `right: 2`
        static let compactRight: CGFloat = 2
        /// `headerIconButton { padding: 4, marginLeft: 2 }`
        static let headerIconPadding: CGFloat = 4
        static let headerIconMargin: CGFloat = 2
        static let headerIconSize: CGFloat = 24

        /// `songInfoLeft.maxWidth` 三种状态的屏宽占比（严格照搬参考源码）：
        /// - compact（歌词/队列/评论页）：`'68%'`
        /// - 歌词页大封面态：`'58%'`
        /// - 主播放页：`'72%'`
        ///
        /// 之前 Swift 写死成 205 / 260pt，在小屏（SE）上会溢出、在大屏（Pro Max）上会留白，
        /// 必须按屏宽百分比换算。
        enum LeftWidthRatio {
            static let compact: CGFloat = 0.68
            static let lyrics: CGFloat = 0.58
            static let normal: CGFloat = 0.72
        }
    }

    // MARK: 底部控制

    enum Controls {
        /// `styles.bottomControls.marginTop: 10`
        static let topMargin: CGFloat = 10
        /// `styles.controlButton.padding: 14`
        static let controlPadding: CGFloat = 14
        /// `SFSymbol size 44` 控制图标
        static let controlIconSize: CGFloat = 44
        /// `styles.playButton 88×88`
        static let playButtonSize: CGFloat = 88
        /// `styles.playPressCircle 76×76 r38 rgba(255,255,255,0.32)`
        static let playPressCircleSize: CGFloat = 76
        static let playPressCircleColor = Color.white.opacity(0.32)
        /// `playControlsRow { marginTop: (layoutSettings.playControlsMarginTop ?? 16) - 12 }`
        static let playRowMarginTop: CGFloat = 4
        /// `styles.progressSection.marginBottom: 12`
        static let progressSectionBottom: CGFloat = 12
        /// `styles.progressTimeRow.marginTop: 12`
        static let progressTimeTop: CGFloat = 12
        /// `styles.progressTimeText.fontSize: 13 / color rgba(255,255,255,0.55)`
        static let timeFontSize: CGFloat = 13
        static let timeColor = Color.white.opacity(0.55)

        /// `styles.sliderContainer { height: 7, borderRadius: 8 }`
        static let trackHeight: CGFloat = 7
        /// 拖动时 `progressTrackH → 15`（160ms out cubic）/ 回弹 7（220ms out cubic）
        static let trackHeightActive: CGFloat = 15
        /// `thumbWidth={12}`；`styles.sliderThumb` 本体 4×4 透明
        static let thumbWidth: CGFloat = 12
        /// `minimumTrackTintColor rgba(255,255,255,0.55)`
        static let trackTint = Color.white.opacity(0.55)
        /// `maximumTrackTintColor rgba(255,255,255,0.18)`
        static let trackBackground = Color.white.opacity(0.18)

        /// `styles.qualityBadge`（进度条中央音质胶囊）
        static let qualityBadgeFill = Color.white.opacity(0.08)
        static let qualityBadgeRadius: CGFloat = 8
        static let qualityBadgeHPadding: CGFloat = 10
        static let qualityBadgeVPadding: CGFloat = 4
        static let qualityBadgeSpacing: CGFloat = 5
        static let qualityBadgeFontSize: CGFloat = 11
        static let qualityBadgeTopMargin: CGFloat = 8

        /// `styles.volumeRow.marginTop: 24`
        static let volumeRowTop: CGFloat = 24
        /// `styles.volumeSliderWrapper.marginHorizontal: 12`
        static let volumeSliderMargin: CGFloat = 12
        /// 音量图标 `speaker.fill size 12 color #a6a6a6` / `speaker.wave.3.fill size 18`
        static let volumeIconSmallSize: CGFloat = 12
        static let volumeIconLargeSize: CGFloat = 18
        static let volumeIconColor = Color(red: 0.65, green: 0.65, blue: 0.65)
        static let volumeIconLargeColor = Color.white.opacity(0.6)

        /// `styles.bottomButtonsRow.marginTop: 20`
        static let bottomButtonsTop: CGFloat = 20
        /// `styles.bottomButton { padding: 10, borderRadius: 12 }`
        static let bottomButtonPadding: CGFloat = 10
        static let bottomButtonRadius: CGFloat = 12
        /// 底部按钮图标 `size 26`
        static let bottomButtonIconSize: CGFloat = 26
        /// `styles.bottomButtonPressed/Active rgba(255,255,255,0.18)`
        static let bottomButtonHighlight = Color.white.opacity(0.18)
        /// 未激活图标色 `#d9d9d9`
        static let bottomButtonIconColor = Color(red: 0.851, green: 0.851, blue: 0.851)

        /// `styles.queueModeBadge { top:-3, right:-3, 18×18, r9, borderWidth hairline, borderColor rgba(255,255,255,0.35) }`
        static let queueBadgeSize: CGFloat = 18
        static let queueBadgeOffset: CGFloat = -3
        static let queueBadgeBorder = Color.white.opacity(0.35)
        static let queueBadgeIconSize: CGFloat = 11
    }

    // MARK: 队列面板

    enum Queue {
        /// `styles.queueScreenTitle { fontSize: 22, weight '500', letterSpacing -0.25 }`
        static let titleFontSize: CGFloat = 22
        static let titleTracking: CGFloat = -0.25
        /// `styles.queueModeSegment { height: 44, borderRadius: 22, borderWidth 1 }`
        static let segmentHeight: CGFloat = 44
        static let segmentRadius: CGFloat = 22
        static let segmentBorder = Color.white.opacity(0.12)
        static let segmentFill = Color.white.opacity(0.055)
        static let segmentItemDivider = Color.white.opacity(0.10)
        static let segmentItemActiveFill = Color.white.opacity(0.13)
        static let segmentGap: CGFloat = 9
        static let segmentTextSize: CGFloat = 16
        static let segmentTextColor = Color.white.opacity(0.78)
        static let segmentBottom: CGFloat = 16

        /// `styles.queueItem`
        static let rowRadius: CGFloat = 14
        static let rowFill = Color.white.opacity(0.08)
        static let rowActiveFill = Color.white.opacity(0.14)
        static let rowDraggingFill = Color.white.opacity(0.2)
        static let rowHPadding: CGFloat = 4
        static let rowVPadding: CGFloat = 10
        static let rowGap: CGFloat = 10
        static let rowSpacing: CGFloat = 10
        static let rowArtworkSize: CGFloat = 48
        static let rowArtworkRadius: CGFloat = 10
        static let rowTitleSize: CGFloat = 16
        static let rowArtistSize: CGFloat = 14
        static let rowTrailingWidth: CGFloat = 30
        static let rowTrailingHeight: CGFloat = 48
        /// `styles.queueListContent { paddingBottom: 210 }`
        static let listPaddingBottom: CGFloat = 210
        static let emptyTextSize: CGFloat = 15
    }

    // MARK: 嵌入面板（截图里的三板横滑，参考源码保留）

    enum Embedded {
        /// `styles.embeddedPanelsContainer { width: SCREEN_WIDTH * 3 - 80 }`
        static let horizontalInset: CGFloat = 40
        /// `styles.embeddedPanelsWrapper { height: 200, marginTop: 12, borderRadius: 16 }`
        static let height: CGFloat = 200
        static let radius: CGFloat = 16
        static let fill = Color.white.opacity(0.08)
        static let padding: CGFloat = 16
        static let lyricFontSize: CGFloat = 16
        static let lyricActiveFontSize: CGFloat = 18
    }

    // MARK: 动画参数（严格照搬参考源码的 spring / timing）

    enum Motion {
        /// `enterCompactMode` / `handleHideCompactMode` 的 `{ damping: 30, stiffness: 220, mass: 1 }`
        /// SwiftUI 近似：response≈0.42, dampingFraction≈1.0（无过冲，响应接近 stiffness 220）
        static let compactSpring = Animation.spring(response: 0.42, dampingFraction: 0.98)
        /// `panelTranslateX` 的 `{ damping: 20, stiffness: 200 }`
        static let panelSpring = Animation.spring(response: 0.38, dampingFraction: 0.82)
        /// `queueSlideAnim` 的 `{ damping: 25, stiffness: 300 }`
        static let queueSpring = Animation.spring(response: 0.32, dampingFraction: 0.86)
        /// `artworkScale` 的 `{ damping: 15, stiffness: 100 }`
        static let artworkSpring = Animation.spring(response: 0.5, dampingFraction: 0.68)

        // MARK: 时长（秒）—— 与 RN withTiming 的 duration 一一对应，动画与测试共用同一常量

        /// 播放/暂停图标交叉淡变 `duration: 180`
        static let playIconCrossfadeDuration: Double = 0.18
        /// 播放按钮圆形按压高亮 `duration: 350, easing: out(quad)`
        static let playPressFadeDuration: Double = 0.35
        /// 进入 compact：`modeOpacity 0→1 / modeTranslateY 22→0`
        static let compactContentInDuration: Double = 0.32
        /// 歌曲信息行淡出 120ms / 淡入 180ms
        static let songInfoFadeOutDuration: Double = 0.12
        static let songInfoFadeInDuration: Double = 0.18
        /// 轨道变粗 `duration: 160` / 回弹 `duration: 220`
        static let trackExpandDuration: Double = 0.16
        static let trackCollapseDuration: Double = 0.22
        /// 动态封面淡入 `duration: 500`
        static let dynamicCoverFadeDuration: Double = 0.5
        /// 兜底背景淡出 `duration: 600`
        static let fallbackBgFadeDuration: Double = 0.6

        /// 播放/暂停图标交叉淡变（`withTiming(..., 180ms)`）
        static let playIconCrossfade = Animation.timingCurve(0.25, 0.46, 0.45, 0.94,
                                                             duration: playIconCrossfadeDuration)
        /// 播放按钮圆形按压高亮（`withTiming(0, 350ms, out(quad))`）
        static let playPressFade = Animation.timingCurve(0.25, 0.46, 0.45, 0.94,
                                                         duration: playPressFadeDuration)
        /// 拖动圆点放大 `{ damping: 10, stiffness: 200 }`
        static let thumbSpring = Animation.spring(response: 0.3, dampingFraction: 0.55)
        /// 轨道变粗 `duration: 160, easing out(cubic)`
        static let trackExpand: Animation = .timingCurve(0.215, 0.61, 0.355, 1,
                                                         duration: trackExpandDuration)
        /// 轨道回弹 `duration: 220, easing out(cubic)`
        static let trackCollapse: Animation = .timingCurve(0.215, 0.61, 0.355, 1,
                                                            duration: trackCollapseDuration)
        /// 进入 compact：320ms easeInOut
        static let compactContentIn: Animation = .easeInOut(duration: compactContentInDuration)
        /// 歌曲信息行淡出 120ms out(quad) / 淡入 180ms out(quad)
        static let songInfoFadeOut: Animation = .timingCurve(0.25, 0.46, 0.45, 0.94,
                                                             duration: songInfoFadeOutDuration)
        static let songInfoFadeIn: Animation = .timingCurve(0.25, 0.46, 0.45, 0.94,
                                                            duration: songInfoFadeInDuration)
        /// 动态封面淡入 `duration: 500`
        static let dynamicCoverFade: Double = dynamicCoverFadeDuration
        /// 兜底背景淡出 `duration: 600`
        static let fallbackBgFade: Double = fallbackBgFadeDuration

        /// 背景流动（`withRepeat(withSequence(...), -1, true)`）
        enum Background {
            /// `bgScale 1.1 → 1.15`，20000ms
            static let scaleFrom: CGFloat = 1.1
            static let scaleTo: CGFloat = 1.15
            static let scaleDuration: Double = 20
            /// `bgTranslateX → -20 → 20`，15000ms
            static let translateX: CGFloat = 20
            static let translateXDuration: Double = 15
            /// `bgTranslateY → -15 → 15`，18000ms
            static let translateY: CGFloat = 15
            static let translateYDuration: Double = 18
        }

        /// 跑马灯
        enum Marquee {
            /// 文本超出容器后才滚动；一个完整循环的时长按文本长度换算
            static let pointsPerSecond: CGFloat = 26
            /// 循环头尾之间的停顿
            static let pause: Double = 1.6
        }
    }
}
