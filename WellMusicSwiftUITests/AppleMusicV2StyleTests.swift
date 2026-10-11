import XCTest
@testable import WellMusicSwiftUI

/// `AppleMusicV2` 常量表与参考源码 `WellMusicAppleMusicV2Player.tsx` 的 StyleSheet 一一对应。
/// 这些断言就是「一摸一样」的回归护栏：数值对不上说明移植被改坏了。
final class AppleMusicV2StyleTests: XCTestCase {

    func testLayoutConstantsMatchReferenceStylesheet() {
        // styles.content.paddingHorizontal: 24
        XCTAssertEqual(AppleMusicV2.contentPadding, 24)
        // styles.artworkWrapper.marginTop: 40
        XCTAssertEqual(AppleMusicV2.artworkWrapperTop, 40)
        // styles.albumArtwork: SCREEN_WIDTH * 0.86 / borderRadius 24
        XCTAssertEqual(AppleMusicV2.artworkWidthRatio, 0.86, accuracy: 0.0001)
        XCTAssertEqual(AppleMusicV2.artworkCornerRadius, 24)
        // styles.albumArtwork shadow: offset.y 18 / opacity 0.5 / radius 32
        XCTAssertEqual(AppleMusicV2.artworkShadowY, 18)
        XCTAssertEqual(AppleMusicV2.artworkShadowRadius, 32)
        XCTAssertEqual(AppleMusicV2.artworkShadowOpacity, 0.5, accuracy: 0.0001)
        // styles.topHomeIndicator: top 60 / 45x5 / r2.5
        XCTAssertEqual(AppleMusicV2.HomeIndicator.top, 60)
        XCTAssertEqual(AppleMusicV2.HomeIndicator.width, 45)
        XCTAssertEqual(AppleMusicV2.HomeIndicator.height, 5)
        XCTAssertEqual(AppleMusicV2.HomeIndicator.radius, 2.5)
    }

    func testCompactModeLandingMatchesEnterCompactMode() {
        // enterCompactMode(): destLeft = 24, destTop = top + 14, S = miniArtworkSize ?? 80
        XCTAssertEqual(AppleMusicV2.Compact.destLeft, 24)
        XCTAssertEqual(AppleMusicV2.Compact.topOffset, 14)
        XCTAssertEqual(AppleMusicV2.Compact.artworkSize, 80)
        // coverInitY = top + 16 + 40 + W * 0.43
        XCTAssertEqual(AppleMusicV2.Compact.coverInitTopBase, 56)
        // 小封面圆角 12（Apple Music 小封面很圆）
        XCTAssertEqual(AppleMusicV2.miniArtworkCornerRadius, 12)
    }

    // MARK: - 封面动态圆角（对应 RN `albumArtRoundStyle`）

    /// 大封面：`sc = 1` → 视觉圆角 24，形状圆角也 24（不折算）。
    func testArtworkRadiusAtLargeScaleIsTwentyFour() {
        let miniScale = 80.0 / (393 * 0.86)   // iPhone 14 Pro 基准
        let radius = AppleMusicV2.ArtworkRadius.shapeRadius(forScale: 1, miniScale: miniScale)
        XCTAssertEqual(radius, 24, accuracy: 0.0001)
    }

    /// 小封面：`sc = miniScale` → 视觉圆角 12。
    /// 形状圆角 = 12 / miniScale，乘以 scale 后视觉落地正好 12。
    func testArtworkRadiusAtMiniScaleLandsOnTwelve() {
        let miniScale = 80.0 / (393 * 0.86)
        let shape = AppleMusicV2.ArtworkRadius.shapeRadius(forScale: miniScale, miniScale: miniScale)
        // 视觉圆角 = 形状圆角 * scale
        XCTAssertEqual(shape * miniScale, 12, accuracy: 0.0001)
    }

    /// 中间任意缩放：视觉圆角线性落在 24 → 12 之间。
    func testArtworkRadiusInterpolatesVisually() {
        let miniScale = 80.0 / (393 * 0.86)
        for step in stride(from: 0.0, through: 1.0, by: 0.1) {
            let sc = miniScale + (1 - miniScale) * CGFloat(step)
            let shape = AppleMusicV2.ArtworkRadius.shapeRadius(forScale: sc, miniScale: miniScale)
            let visual = shape * sc
            let expected = 12 + (24 - 12) * CGFloat(step)
            XCTAssertEqual(visual, expected, accuracy: 0.0001,
                           "sc=\(sc) 时视觉圆角应为 \(expected)，实际 \(visual)")
        }
    }

    /// 两端常量本身就是 24 / 12，防止有人把公式里的魔法数改掉。
    func testArtworkRadiusEndpointsArePinned() {
        XCTAssertEqual(AppleMusicV2.ArtworkRadius.large, 24)
        XCTAssertEqual(AppleMusicV2.ArtworkRadius.mini, 12)
    }

    /// 退化保护：`miniScale >= 1`（大/小封面同尺寸）时不得除零/产生 NaN。
    func testArtworkRadiusDoesNotBlowUpWhenMiniScaleIsOne() {
        let radius = AppleMusicV2.ArtworkRadius.shapeRadius(forScale: 1, miniScale: 1)
        XCTAssertTrue(radius.isFinite)
        XCTAssertEqual(radius, 24, accuracy: 0.0001)
    }

    /// `scale` 传入 0 或负数时按 0.1 兜底（对应 RN `Math.max(coverScaleAnim.value, 0.1)`）。
    func testArtworkRadiusClampsNonPositiveScale() {
        let miniScale = 80.0 / (393 * 0.86)
        let zero = AppleMusicV2.ArtworkRadius.shapeRadius(forScale: 0, miniScale: miniScale)
        let clamped = AppleMusicV2.ArtworkRadius.shapeRadius(forScale: 0.1, miniScale: miniScale)
        XCTAssertEqual(zero, clamped, accuracy: 0.0001)
        XCTAssertTrue(zero.isFinite)
    }

    func testTitleStyleMatchesReference() {
        // styles.songTitle: fontSize 18 / fontWeight 600
        XCTAssertEqual(AppleMusicV2.Title.fontSize, 18)
        // styles.songArtist / songAlbum: fontSize 14 / fontWeight 500
        XCTAssertEqual(AppleMusicV2.Title.metaFontSize, 14)
        // styles.songMetaRow.marginTop: 4
        XCTAssertEqual(AppleMusicV2.Title.metaSpacing, 4)
        // styles.songInfoRight.marginLeft: 12
        XCTAssertEqual(AppleMusicV2.Title.rightMarginLeft, 12)
        // compact 落点: left = miniArtworkSize + 8, top = miniArtworkSize / 2 - 18, right = 2
        XCTAssertEqual(AppleMusicV2.Title.compactLeftGap, 8)
        XCTAssertEqual(AppleMusicV2.Title.compactTopAnchor, 18)
        XCTAssertEqual(AppleMusicV2.Title.compactRight, 2)
        // headerIconButton: padding 4, marginLeft 2
        XCTAssertEqual(AppleMusicV2.Title.headerIconPadding, 4)
        XCTAssertEqual(AppleMusicV2.Title.headerIconMargin, 2)
    }

    func testControlsMatchReference() {
        // styles.playButton: 88x88；playPressCircle 76x76
        XCTAssertEqual(AppleMusicV2.Controls.playButtonSize, 88)
        XCTAssertEqual(AppleMusicV2.Controls.playPressCircleSize, 76)
        // SFSymbol size 44 控制图标
        XCTAssertEqual(AppleMusicV2.Controls.controlIconSize, 44)
        // styles.sliderContainer height 7，拖动时 trackH -> 15
        XCTAssertEqual(AppleMusicV2.Controls.trackHeight, 7)
        XCTAssertEqual(AppleMusicV2.Controls.trackHeightActive, 15)
        XCTAssertEqual(AppleMusicV2.Controls.thumbWidth, 12)
        // styles.progressTimeText: fontSize 13
        XCTAssertEqual(AppleMusicV2.Controls.timeFontSize, 13)
        // styles.qualityBadge: paddingH 10 / paddingV 4 / radius 8 / gap 5 / fontSize 11
        XCTAssertEqual(AppleMusicV2.Controls.qualityBadgeHPadding, 10)
        XCTAssertEqual(AppleMusicV2.Controls.qualityBadgeVPadding, 4)
        XCTAssertEqual(AppleMusicV2.Controls.qualityBadgeRadius, 8)
        XCTAssertEqual(AppleMusicV2.Controls.qualityBadgeSpacing, 5)
        XCTAssertEqual(AppleMusicV2.Controls.qualityBadgeFontSize, 11)
        // styles.volumeRow.marginTop: 24
        XCTAssertEqual(AppleMusicV2.Controls.volumeRowTop, 24)
        // styles.volumeSliderWrapper.marginHorizontal: 12
        XCTAssertEqual(AppleMusicV2.Controls.volumeSliderMargin, 12)
        // styles.bottomButtonsRow.marginTop: 20
        XCTAssertEqual(AppleMusicV2.Controls.bottomButtonsTop, 20)
        // styles.bottomButton: padding 10 / radius 12 / icon 26
        XCTAssertEqual(AppleMusicV2.Controls.bottomButtonPadding, 10)
        XCTAssertEqual(AppleMusicV2.Controls.bottomButtonRadius, 12)
        XCTAssertEqual(AppleMusicV2.Controls.bottomButtonIconSize, 26)
        // styles.queueModeBadge: 18x18 / -3 / icon 11
        XCTAssertEqual(AppleMusicV2.Controls.queueBadgeSize, 18)
        XCTAssertEqual(AppleMusicV2.Controls.queueBadgeOffset, -3)
        XCTAssertEqual(AppleMusicV2.Controls.queueBadgeIconSize, 11)
    }

    func testQueuePanelMatchesReference() {
        // styles.queueScreenTitle: fontSize 22 / letterSpacing -0.25
        XCTAssertEqual(AppleMusicV2.Queue.titleFontSize, 22)
        XCTAssertEqual(AppleMusicV2.Queue.titleTracking, -0.25, accuracy: 0.0001)
        // styles.queueModeSegment: height 44 / radius 22 / marginBottom 16
        XCTAssertEqual(AppleMusicV2.Queue.segmentHeight, 44)
        XCTAssertEqual(AppleMusicV2.Queue.segmentRadius, 22)
        XCTAssertEqual(AppleMusicV2.Queue.segmentBottom, 16)
        XCTAssertEqual(AppleMusicV2.Queue.segmentGap, 9)
        // styles.queueItem: r14 / paddingV 10 / gap 10 / artwork 48 r10
        XCTAssertEqual(AppleMusicV2.Queue.rowRadius, 14)
        XCTAssertEqual(AppleMusicV2.Queue.rowVPadding, 10)
        XCTAssertEqual(AppleMusicV2.Queue.rowGap, 10)
        XCTAssertEqual(AppleMusicV2.Queue.rowArtworkSize, 48)
        XCTAssertEqual(AppleMusicV2.Queue.rowArtworkRadius, 10)
        // styles.queueItemTitle: 16 / queueItemArtist: 14
        XCTAssertEqual(AppleMusicV2.Queue.rowTitleSize, 16)
        XCTAssertEqual(AppleMusicV2.Queue.rowArtistSize, 14)
        // styles.queueListContent: paddingBottom 210
        XCTAssertEqual(AppleMusicV2.Queue.listPaddingBottom, 210)
    }

    func testMotionParametersMatchReference() {
        // playPressAnim: withTiming(0, 350ms, out(quad))
        XCTAssertEqual(AppleMusicV2.Motion.playPressFadeDuration, 0.35, accuracy: 0.0001)
        // 播放/暂停交叉过渡: withTiming(..., 180ms)
        XCTAssertEqual(AppleMusicV2.Motion.playIconCrossfadeDuration, 0.18, accuracy: 0.0001)
        // enterCompactMode: songInfoOpacity 120ms out(quad) 淡出 / 180ms 淡入
        XCTAssertEqual(AppleMusicV2.Motion.songInfoFadeOutDuration, 0.12, accuracy: 0.0001)
        XCTAssertEqual(AppleMusicV2.Motion.songInfoFadeInDuration, 0.18, accuracy: 0.0001)
        // modeOpacity / modeTranslateY: withTiming(..., 320ms, inOut)
        XCTAssertEqual(AppleMusicV2.Motion.compactContentInDuration, 0.32, accuracy: 0.0001)
        // 轨道: withTiming(15, 160ms) / withTiming(7, 220ms)
        XCTAssertEqual(AppleMusicV2.Motion.trackExpandDuration, 0.16, accuracy: 0.0001)
        XCTAssertEqual(AppleMusicV2.Motion.trackCollapseDuration, 0.22, accuracy: 0.0001)
        // 动态封面淡入 500ms / 兜底淡出 600ms
        XCTAssertEqual(AppleMusicV2.Motion.dynamicCoverFadeDuration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(AppleMusicV2.Motion.fallbackBgFadeDuration, 0.6, accuracy: 0.0001)
        // 兼容别名与主常量一致
        XCTAssertEqual(AppleMusicV2.Motion.dynamicCoverFade, AppleMusicV2.Motion.dynamicCoverFadeDuration)
        XCTAssertEqual(AppleMusicV2.Motion.fallbackBgFade, AppleMusicV2.Motion.fallbackBgFadeDuration)
    }

    func testBackgroundFlowAnimationMatchesReference() {
        // bgScale: 1.1 -> 1.15，20000ms
        XCTAssertEqual(AppleMusicV2.Motion.Background.scaleFrom, 1.1, accuracy: 0.0001)
        XCTAssertEqual(AppleMusicV2.Motion.Background.scaleTo, 1.15, accuracy: 0.0001)
        XCTAssertEqual(AppleMusicV2.Motion.Background.scaleDuration, 20)
        // bgTranslateX: -20 -> 20，15000ms
        XCTAssertEqual(AppleMusicV2.Motion.Background.translateX, 20)
        XCTAssertEqual(AppleMusicV2.Motion.Background.translateXDuration, 15)
        // bgTranslateY: -15 -> 15，18000ms
        XCTAssertEqual(AppleMusicV2.Motion.Background.translateY, 15)
        XCTAssertEqual(AppleMusicV2.Motion.Background.translateYDuration, 18)
    }
}
