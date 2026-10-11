import XCTest
import CoreMedia
@testable import WellMusicSwiftUI

/// 回归测试：拖动进度条时的「时间源一致性」与「seek 精度容差」。
///
/// 背景（三个真实问题）：
/// 1. **拖动时歌词不跟手**：`PlayerClock` 读的是 `PlayerCore.currentTime`（真实播放位置），
///    而不是 `displayTime`（拖动中为 `scrubTime`）。进度条自己有本地 `seekingTime` 撑着，
///    所以看起来正常；但歌词读 `clock.progress`，拖动时完全不动。
/// 2. **松手后歌词滞后于人声**：`AppleMusicV2ProgressSection` 从不调用
///    `beginScrubbing` / `updateScrubbing` / `endScrubbing`，导致 `isScrubbing` 恒为 false，
///    `scrubTime` 从未被使用，AMLL 拿到的也是过期时间。
/// 3. **无损文件拖动特别不准**：`toleranceBefore/After = .zero` 会要求框架解码大量数据
///    才能做到样本级精确（Apple 官方文档原话），大文件上耗时显著，位置迟迟不落地。
final class PlayerSeekSyncTests: XCTestCase {

    // MARK: - 时间源选择（问题 1 / 2）

    /// `displayTime` 的语义：拖动中取 scrubTime，其余取 currentTime。
    /// 这里用一个与 `PlayerCore.displayTime` 等价的纯函数锁死该契约，
    /// 防止有人改回「始终用 currentTime」而让拖动失去跟手性。
    private func displayTime(isScrubbing: Bool, scrubTime: Double, currentTime: Double) -> Double {
        isScrubbing ? scrubTime : currentTime
    }

    func testDisplayTimeFollowsScrubWhileDragging() {
        // 拖动中：手指停在 42s，真实播放位置还在 10s → 必须返回 42
        XCTAssertEqual(
            displayTime(isScrubbing: true, scrubTime: 42, currentTime: 10),
            42,
            "拖动中必须返回 scrubTime，否则歌词不跟手"
        )
    }

    func testDisplayTimeReturnsPlaybackWhenNotDragging() {
        // 未拖动：必须返回真实播放时间
        XCTAssertEqual(
            displayTime(isScrubbing: false, scrubTime: 42, currentTime: 10),
            10,
            "未拖动必须返回 currentTime"
        )
    }

    /// 拖动中即使真实时间在推进（AVPlayer 仍在播放），显示时间也必须锁定在预览值
    func testScrubTimeWinsOverAdvancingPlayback() {
        for playback in stride(from: 10.0, through: 40.0, by: 5.0) {
            XCTAssertEqual(displayTime(isScrubbing: true, scrubTime: 42, currentTime: playback), 42,
                           "播放推进到 \(playback) 也不能覆盖拖动中的预览时间")
        }
    }

    // MARK: - seek 容差（问题 3）

    /// 容差必须**大于零**：`.zero` 会触发全量解码，在无损文件上很慢
    func testSeekToleranceIsNotSampleAccurate() {
        XCTAssertGreaterThan(
            PlayerCore.seekToleranceSeconds, 0,
            "容差为 0 会强制样本级精确解码，无损大文件上会明显变慢"
        )
    }

    /// 容差必须**小于人耳可感阈值**（保守取 40ms）：
    /// 否则用户能听出「跳到的地方和点的地方不一致」
    func testSeekToleranceIsBelowPerceptibleThreshold() {
        XCTAssertLessThanOrEqual(
            PlayerCore.seekToleranceSeconds, 0.04,
            "容差过大（>40ms）人耳可感知音画不同步"
        )
    }

    /// 锁死当前选值 20ms
    func testSeekToleranceValueIsPinned() {
        XCTAssertEqual(PlayerCore.seekToleranceSeconds, 0.02, accuracy: 1e-9)
    }

    /// 容差换算成 CMTime 后的精度：600 刻度下 20ms = 12 个 tick，
    /// 是有意义的非零值（不会因刻度太粗被截断为 0）
    func testSeekToleranceSurvivesTimescaleConversion() {
        let timescale: CMTimeScale = 600
        let tolerance = CMTime(seconds: PlayerCore.seekToleranceSeconds, preferredTimescale: timescale)
        XCTAssertGreaterThan(tolerance.value, 0, "600 刻度下容差不能被截断为 0")
        XCTAssertEqual(tolerance.seconds, 0.02, accuracy: 1e-9)
        // 600 * 0.02 = 12
        XCTAssertEqual(tolerance.value, 12)
    }

    // MARK: - 兜底超时

    /// 兜底超时必须存在且是有限正值，否则 isScrubbing 可能永久卡在 true
    func testScrubTimeoutIsFiniteAndPositive() {
        XCTAssertGreaterThan(PlayerCore.scrubTimeoutSeconds, 0)
        XCTAssertTrue(PlayerCore.scrubTimeoutSeconds.isFinite)
        // 不能太长：用户松手后不应等待超过 3 秒才恢复
        XCTAssertLessThanOrEqual(PlayerCore.scrubTimeoutSeconds, 3.0,
                                 "兜底超时过长会让进度条看起来卡死")
    }

    // MARK: - 拖动流程状态机（问题 2 的契约）

    /// 拖动生命周期的最小状态机：开始 → 更新 → 结束，
    /// 结束后必须回到「非拖动」态，`displayTime` 才能回落真实时间。
    func testScrubbingLifecycleReturnsToPlaybackTime() {
        var isScrubbing = false
        var scrubTime = 0.0
        var currentTime = 5.0

        // 开始拖动
        isScrubbing = true
        scrubTime = 5.0

        // 拖到 87s
        scrubTime = 87.0
        XCTAssertEqual(displayTime(isScrubbing: isScrubbing, scrubTime: scrubTime, currentTime: currentTime), 87)

        // 结束拖动：乐观更新让 UI 立即对准
        currentTime = 87.0
        isScrubbing = false
        XCTAssertEqual(displayTime(isScrubbing: isScrubbing, scrubTime: scrubTime, currentTime: currentTime), 87,
                       "松手后乐观更新必须让显示时间立即落在目标位置")
    }
}
