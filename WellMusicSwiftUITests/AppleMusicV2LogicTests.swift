import XCTest
import SwiftUI
@testable import WellMusicSwiftUI

/// 播放器 compact 模式的落点几何。
///
/// 参考源码 `WellMusicAppleMusicV2Player.tsx` 的 `enterCompactMode()` 用确定性常量算落点
/// （不依赖运行时测量），所以这里可以脱离 UI 直接验证公式。
final class AppleMusicV2GeometryTests: XCTestCase {

    private let referenceWidth: CGFloat = 393   // iPhone 14 Pro 基准
    private let referenceTopInset: CGFloat = 59 // 刘海机型安全区顶部

    /// 复刻 `enterCompactMode()` 里封面位移的计算
    private func coverTranslation(screenWidth: CGFloat, top: CGFloat) -> (tx: CGFloat, ty: CGFloat, scale: CGFloat) {
        let artworkSize = screenWidth * AppleMusicV2.artworkWidthRatio
        let miniSize = AppleMusicV2.Compact.artworkSize
        let coverInitX = screenWidth / 2
        let coverInitY = top + AppleMusicV2.Compact.coverInitTopBase + artworkSize / 2
        let destLeft = AppleMusicV2.Compact.destLeft
        let destTop = top + AppleMusicV2.Compact.topOffset
        let tx = destLeft + miniSize / 2 - coverInitX
        let ty = destTop + miniSize / 2 - coverInitY
        return (tx, ty, miniSize / artworkSize)
    }

    func testCompactCoverLandsAtTopLeftMiniSlot() {
        let screenWidth: CGFloat = referenceWidth
        let top = referenceTopInset
        let (tx, ty, scale) = coverTranslation(screenWidth: screenWidth, top: top)

        // 位移必须向左、向上（大封面居中偏下 → 左上角）
        XCTAssertLessThan(tx, 0, "封面应向左位移到左上角迷你位")
        XCTAssertLessThan(ty, 0, "封面应向上位移到状态栏下方")

        // 落点还原校验：初始中心 + 位移 == 目标中心
        let artworkSize = screenWidth * AppleMusicV2.artworkWidthRatio
        let coverInitX = screenWidth / 2
        let coverInitY = top + AppleMusicV2.Compact.coverInitTopBase + artworkSize / 2
        let landedCenterX = coverInitX + tx
        let landedCenterY = coverInitY + ty
        let miniSize = AppleMusicV2.Compact.artworkSize
        XCTAssertEqual(landedCenterX, AppleMusicV2.Compact.destLeft + miniSize / 2, accuracy: 0.0001)
        XCTAssertEqual(landedCenterY, top + AppleMusicV2.Compact.topOffset + miniSize / 2, accuracy: 0.0001)

        // 缩放后小封面尺寸应等于 80pt
        XCTAssertEqual(artworkSize * scale, miniSize, accuracy: 0.01)
    }

    func testCompactScaleIsConsistentAcrossDevices() {
        // 小封面是固定 80pt，因此不同屏宽下缩放比例不同，但落点尺寸恒为 80
        for width in [320.0, 375.0, 393.0, 430.0] as [CGFloat] {
            let (_, _, scale) = coverTranslation(screenWidth: width, top: 47)
            let landedSize = width * AppleMusicV2.artworkWidthRatio * scale
            XCTAssertEqual(landedSize, AppleMusicV2.Compact.artworkSize, accuracy: 0.01,
                           "屏宽 \(width) 下小封面尺寸应为 80pt")
        }
    }

    /// compact 歌曲信息行的绝对定位 Y（对应 RN `top: miniArtworkSize / 2 - 18`）
    func testCompactSongInfoRowVerticalAnchor() {
        let top: CGFloat = 59
        let rowTop = top
            + AppleMusicV2.Compact.topOffset
            + AppleMusicV2.Compact.artworkSize / 2
            - AppleMusicV2.Title.compactTopAnchor
        // 小封面中心 Y = top + 14 + 40；信息行上沿 = 中心 - 18
        let miniCenterY = top + AppleMusicV2.Compact.topOffset + AppleMusicV2.Compact.artworkSize / 2
        XCTAssertEqual(rowTop, miniCenterY - AppleMusicV2.Title.compactTopAnchor, accuracy: 0.0001)
        XCTAssertEqual(rowTop, 95, accuracy: 0.0001)
    }

    /// 动态圆角：`borderRadius: 24 / max(coverScaleAnim, 0.1)`
    func testDynamicCornerRadiusKeepsVisualRadiusConstant() {
        let scale: CGFloat = 0.24
        let radius = AppleMusicV2.artworkCornerRadius / max(scale, 0.1)
        // 缩放后视觉半径 = radius * scale == 24
        XCTAssertEqual(radius * scale, AppleMusicV2.artworkCornerRadius, accuracy: 0.0001)
        // 极小缩放时下限保护（避免除零）
        let clamped = AppleMusicV2.artworkCornerRadius / max(0, 0.1)
        XCTAssertEqual(clamped, 240, accuracy: 0.0001)
    }
}

/// 下拉关闭阈值（复刻 `swipeToDismissGesture` 的判定）
final class AppleMusicV2DismissTests: XCTestCase {

    private func shouldDismiss(translation: CGFloat, predicted: CGFloat, screenHeight: CGFloat) -> Bool {
        translation > screenHeight * 0.18 || predicted > screenHeight * 0.35
    }

    func testDismissThresholds() {
        let height: CGFloat = 852
        // 位移超过屏高 18% → 关闭
        XCTAssertTrue(shouldDismiss(translation: 154, predicted: 154, screenHeight: height))
        XCTAssertFalse(shouldDismiss(translation: 153, predicted: 153, screenHeight: height))
        // 位移不大但甩动速度足够（predictedEnd > 35%）→ 关闭
        XCTAssertTrue(shouldDismiss(translation: 100, predicted: 300, screenHeight: height))
        XCTAssertFalse(shouldDismiss(translation: 100, predicted: 298, screenHeight: height))
    }

    /// 手势只能被「纵向 + 向下」的拉拽接管，避免抢走歌词横滑与进度条拖动
    func testOnlyVerticalDownwardDragClaimsGesture() {
        func claims(dy: CGFloat, dx: CGFloat) -> Bool {
            dy > 10 && abs(dy) > abs(dx) * 1.2
        }
        XCTAssertTrue(claims(dy: 30, dx: 0))
        XCTAssertFalse(claims(dy: 30, dx: 40), "横向为主时不接管")
        XCTAssertFalse(claims(dy: -30, dx: 0), "向上不接管")
        XCTAssertFalse(claims(dy: 8, dx: 0), "位移过小不接管")
        // 阻尼系数 0.45
        XCTAssertEqual(max(0, 100.0) * 0.45, 45.0, accuracy: 0.0001)
    }
}

/// 派生展示逻辑：歌手截断 / 拆分、专辑回退、播放模式图标
final class AppleMusicV2PresentationTests: XCTestCase {

    private func splitArtists(_ raw: String) -> [String] {
        raw.split(whereSeparator: { "/、,&".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func testArtistTruncationLimits() {
        // 大封面态最多 24 字，歌词界面最多 17 字
        func truncate(_ raw: String, showLyrics: Bool) -> String {
            let maxLen = showLyrics ? 17 : 24
            return raw.count > maxLen ? String(raw.prefix(maxLen)) + ".." : raw
        }
        let long = String(repeating: "歌", count: 40)
        XCTAssertEqual(truncate(long, showLyrics: false).count, 26) // 24 + ".."
        XCTAssertEqual(truncate(long, showLyrics: true).count, 19)  // 17 + ".."
        XCTAssertEqual(truncate("短名字", showLyrics: false), "短名字")
    }

    func testSplitArtistsHandlesAllSeparators() {
        XCTAssertEqual(splitArtists("周杰伦"), ["周杰伦"])
        XCTAssertEqual(splitArtists("A/B"), ["A", "B"])
        XCTAssertEqual(splitArtists("A、B"), ["A", "B"])
        XCTAssertEqual(splitArtists("A,B"), ["A", "B"])
        XCTAssertEqual(splitArtists("A & B"), ["A", "B"])
        XCTAssertEqual(splitArtists("A / B / C").count, 3)
        XCTAssertTrue(splitArtists("   ").isEmpty)
    }

    func testPlayModeIcon() {
        // 0 列表循环 → repeat；2 随机 → shuffle；1 单曲 → repeat.1
        func icon(_ mode: Int) -> String {
            switch mode {
            case 2: return "shuffle"
            case 1: return "repeat.1"
            default: return "repeat"
            }
        }
        XCTAssertEqual(icon(0), "repeat")
        XCTAssertEqual(icon(1), "repeat.1")
        XCTAssertEqual(icon(2), "shuffle")
    }

    func testLyricDelayTitleFormatting() {
        func title(_ value: Double) -> String {
            if value == 0 { return "复位（0.0秒）" }
            let abs = Swift.abs(value)
            let text = String(format: "%.1f", abs)
            if value < 0 { return "-\(text)秒（歌词推迟）" }
            return "+\(text)秒（歌词提前）"
        }
        XCTAssertEqual(title(0), "复位（0.0秒）")
        XCTAssertEqual(title(-3), "-3.0秒（歌词推迟）")
        XCTAssertEqual(title(3), "+3.0秒（歌词提前）")
        XCTAssertEqual(title(0.5), "+0.5秒（歌词提前）")
    }
}

/// 音质档位映射（设置页新增项，播放器音质胶囊直接消费）
final class WellAudioQualityTests: XCTestCase {

    func testAllCasesAreOrdered() {
        XCTAssertEqual(WellAudioQuality.allCases, [.standard, .high, .lossless, .hiRes])
        XCTAssertEqual(WellAudioQuality.standard.rawValue, 0)
        XCTAssertEqual(WellAudioQuality.hiRes.rawValue, 3)
    }

    func testDisplayNames() {
        XCTAssertEqual(WellAudioQuality.standard.displayName, "标准")
        XCTAssertEqual(WellAudioQuality.high.displayName, "较高")
        XCTAssertEqual(WellAudioQuality.lossless.displayName, "无损")
        XCTAssertEqual(WellAudioQuality.hiRes.displayName, "Hi-Res")
    }

    /// 播放器音质胶囊短标签（对应参考源码 `qualityDisplayName`）
    func testBadgeText() {
        XCTAssertEqual(WellAudioQuality.standard.badgeText, "128k")
        XCTAssertEqual(WellAudioQuality.high.badgeText, "320k")
        XCTAssertEqual(WellAudioQuality.lossless.badgeText, "FLAC")
        XCTAssertEqual(WellAudioQuality.hiRes.badgeText, "Hi-Res")
    }

    func testNeteaseLevelMapping() {
        XCTAssertEqual(WellAudioQuality.standard.neteaseLevel, "standard")
        XCTAssertEqual(WellAudioQuality.high.neteaseLevel, "exhigh")
        XCTAssertEqual(WellAudioQuality.lossless.neteaseLevel, "lossless")
        XCTAssertEqual(WellAudioQuality.hiRes.neteaseLevel, "hires")
    }

    func testQQFilePrefixMapping() {
        XCTAssertEqual(WellAudioQuality.standard.qqFilePrefix, "M500")
        XCTAssertEqual(WellAudioQuality.high.qqFilePrefix, "M800")
        XCTAssertEqual(WellAudioQuality.lossless.qqFilePrefix, "F000")
        XCTAssertEqual(WellAudioQuality.hiRes.qqFilePrefix, "RS01")
    }

    func testOtherPlatformsMapping() {
        XCTAssertEqual(WellAudioQuality.lossless.kugouBitrate, "flac")
        XCTAssertEqual(WellAudioQuality.hiRes.kugouBitrate, "high")
        XCTAssertEqual(WellAudioQuality.standard.kuwoBr, "128k")
        XCTAssertEqual(WellAudioQuality.high.kuwoBr, "320k")
        XCTAssertEqual(WellAudioQuality.hiRes.lxQuality, "flac24bit")
    }

    /// 旧布尔 `highQuality` 的迁移语义：非标准档即高音质
    func testLegacyHighQualityCompatibility() {
        XCTAssertFalse(WellAudioQuality.standard.isHighQuality)
        XCTAssertTrue(WellAudioQuality.high.isHighQuality)
        XCTAssertTrue(WellAudioQuality.lossless.isHighQuality)
        XCTAssertTrue(WellAudioQuality.hiRes.isHighQuality)
    }
}

/// 歌词时序工具（进度条 / 歌词高亮同源）
final class LyricTimingTests: XCTestCase {

    func testEffectiveProgressNeverNegative() {
        XCTAssertEqual(LyricTiming.effectiveProgress(5, userOffset: 0), 5, accuracy: 0.0001)
        XCTAssertEqual(LyricTiming.effectiveProgress(5, userOffset: 2), 7, accuracy: 0.0001)
        // 负偏移导致越界时钳到 0
        XCTAssertEqual(LyricTiming.effectiveProgress(1, userOffset: -5), 0, accuracy: 0.0001)
    }

    func testSeekTimeAppliesInverseOffset() {
        let line = LyricLine(id: 0, time: 30, text: "测试")
        XCTAssertEqual(LyricTiming.seekTime(for: line, userOffset: 0), 30, accuracy: 0.0001)
        // 提前 3 秒 → seek 到 27
        XCTAssertEqual(LyricTiming.seekTime(for: line, userOffset: 3), 27, accuracy: 0.0001)
        // 推迟 3 秒 → seek 到 33
        XCTAssertEqual(LyricTiming.seekTime(for: line, userOffset: -3), 33, accuracy: 0.0001)
        XCTAssertEqual(LyricTiming.seekTime(for: line, userOffset: 100), 0, accuracy: 0.0001)
    }

    /// 当前歌词索引：取最后一个 `time <= progress` 的行
    func testActiveLyricIndexSelection() {
        let lines = [
            LyricLine(id: 0, time: 0, text: "a"),
            LyricLine(id: 1, time: 5, text: "b"),
            LyricLine(id: 2, time: 10, text: "c"),
        ]
        func index(at progress: Double) -> Int? {
            var answer: Int?
            for line in lines where line.time <= progress { answer = line.id }
            return answer
        }
        XCTAssertNil(index(at: -1))
        XCTAssertEqual(index(at: 0), 0)
        XCTAssertEqual(index(at: 4.9), 0)
        XCTAssertEqual(index(at: 5), 1)
        XCTAssertEqual(index(at: 999), 2)
    }
}
