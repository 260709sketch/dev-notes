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
