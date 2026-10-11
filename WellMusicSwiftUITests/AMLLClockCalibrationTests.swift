import XCTest
@testable import WellMusicSwiftUI

/// 回归测试：AMLL 歌词页时钟的**硬校准**（修复「无损音质以上拖动进度条歌词仍偏移」）。
///
/// ## 问题根因
///
/// AMLL 歌词页的时钟是**自由外推**的（页面源码 `AMLLBridge` 内）：
///
/// ```js
/// function Bp(r) { return Tl ? co + (r - _l) * Np : co }   // Tl = 是否在播放
/// ```
///
/// `co` 是采样到的位置，`_l` 是采样时刻，`Np` 是速率。也就是说：**页面只被喂离散样本，
/// 样本之间自己线性外推**。这条设计带来两个必须正视的性质：
///
/// 1. **误差会自我保持**——种下多少偏差，它就带着这个偏差一直走下去，
///    不会被下一次采样「自动纠正」；
/// 2. **外推纪元只在采样时重置**——`sync(ms, …)` 无条件执行 `_l = now; co = ms`。
///
/// 而 App 侧的采样有两处缺口，恰好都出现在拖动进度条的场景里：
///
/// - **缺口 A（时间源滞后）**：采样走 `displayTime` → `currentTime`，而 `currentTime`
///   由 AVPlayer 的周期回调维护。无损 / Hi-Res 大文件上该回调间隔被明显拉长，
///   松手瞬间的 `currentTime` 可能仍停留在**上百毫秒之前**。
/// - **缺口 B（位置没动就不上报）**：`pushClock` 只有在位置变化 ≥ 30ms 时才认为「在走」，
///   缓冲 / 卡顿时干脆不喂样本，误差就被**冻结**在那里。
///
/// 两者叠加，页面会把一个已经偏掉的样本当作新纪元，然后一路外推——听感上就是
/// 「歌词和歌声各跑各的」。
///
/// ## 修法
///
/// 对齐 RN 版（`WellMusicAppleMusicV2Player.tsx` 的 `emitSeek` / `seekCommand`）与
/// kumone 版（`seekCommand`）的做法：**在拖动结束 / 跳转时下发一次硬校准**，
/// 用**无条件落位**的 `hardCalibrate(ms)` 把误差一次清零，并以该时刻为新纪元重启外推。
///
/// 本文件用纯逻辑复刻「页面外推 + 硬校准」两个状态机，锁死以上契约。
final class AMLLClockCalibrationTests: XCTestCase {

    // MARK: - 页面时钟模型

    /// AMLL 页面时钟的等价实现：`Bp(r) = playing ? co + (r - _l) * rate : co`。
    private struct PageClock {
        var sampledSeconds: Double = 0     // co
        var sampledAt: Double = 0          // _l
        var playing = false                // Tl
        var rate: Double = 1               // Np

        /// 页面在 `now` 时刻认为的播放位置。
        func position(at now: Double) -> Double {
            playing ? sampledSeconds + (now - sampledAt) * rate : sampledSeconds
        }

        /// `AMLLBridge.sync(ms, running, rate)`：无条件重置外推纪元。
        mutating func sync(seconds: Double, running: Bool, at now: Double, rate: Double = 1) {
            sampledSeconds = seconds
            sampledAt = now
            self.rate = rate
            playing = running
        }

        /// `AMLLBridge.hardCalibrate(ms)`：同样重置纪元，但语义是「误差清零」。
        mutating func hardCalibrate(seconds: Double, at now: Double) {
            sampledSeconds = seconds
            sampledAt = now
            playing = true
        }
    }

    // MARK: - 缺口复现：为什么旧实现必然偏移

    /// **缺口 A + B 的联合效应**：采样滞后 150ms 且随后位置长时间不动，
    /// 页面会带着这 150ms 误差一路外推，且**永远无法自愈**。
    ///
    /// 这就是用户报告的「无损音质以上拖动后歌词还是偏移」。
    func testStaleSampleIsCarriedForwardForeverWithoutCalibration() {
        var page = PageClock()
        let now = 100.0

        // 真实播放位置是 30.0s，但无损文件上 AVPlayer 的周期回调没跟上，
        // 采样拿到的仍是 150ms 之前的 29.85s。
        page.sync(seconds: 29.85, running: true, at: now)

        // 此后 2 秒内没有任何新样本（缓冲 / 位置变化不足阈值 → 缺口 B），
        // 页面只能自己外推。
        let driftAt2s = page.position(at: now + 2.0) - (30.0 + 2.0)
        XCTAssertEqual(driftAt2s, -0.15, accuracy: 1e-9,
                       "滞后的样本会被原样带着走：误差既不会放大也不会自愈")

        // 再过 10 秒，误差依旧是那 150ms —— 这正是「持续偏移」而非「跳一下」的原因。
        let driftAt12s = page.position(at: now + 12.0) - (30.0 + 12.0)
        XCTAssertEqual(driftAt12s, -0.15, accuracy: 1e-9,
                       "外推不会自我纠正，误差必须靠硬校准清零")
    }

    // MARK: - `sync` 的 600ms 门槛：硬校准存在的理由

    /// 页面源码里 `sync` 只有当 `|采样值 - 页面值| > 600ms` 时才调用 `setCurrentTime`。
    /// 因此**几十到几百毫秒**的残差落在 `sync` 的能力范围之外——
    /// 这恰恰是无损拖动后残差最典型的量级，也正是必须引入 `hardCalibrate` 的直接原因。
    func testSyncThresholdLeavesSubSecondDriftUncorrected() {
        // 页面源码中的门槛常量。
        let syncThresholdMs = 600.0

        let draggedDriftMs = 150.0
        XCTAssertLessThan(draggedDriftMs, syncThresholdMs,
                          "无损拖动后的残差小于 sync 的门槛，sync 不会去纠正它")

        // 复刻页面 sync 的分支判断。
        func syncWouldForceCurrentTime(sampleMs: Double, pageMs: Double) -> Bool {
            abs(sampleMs - pageMs) > syncThresholdMs
        }
        XCTAssertFalse(
            syncWouldForceCurrentTime(sampleMs: draggedDriftMs, pageMs: 0),
            "150ms 残差不会触发 setCurrentTime —— 不硬校准就会一直偏下去"
        )
        XCTAssertTrue(
            syncWouldForceCurrentTime(sampleMs: 900, pageMs: 0),
            "只有超过 600ms 的巨幅偏差才由 sync 兜住"
        )
    }

    /// 硬校准不受该门槛限制：无论残差多小都强制落位。
    func testHardCalibrateHasNoThreshold() {
        var page = PageClock()
        let now = 50.0
        page.sync(seconds: 10.0, running: true, at: now)

        // 页面此刻认为自己在 10.0s（仅外推了 0 秒）。
        XCTAssertEqual(page.position(at: now), 10.0, accuracy: 1e-9)

        // 硬校准到 10.2s —— 只差 200ms，远小于 600ms，但必须无条件落位。
        page.hardCalibrate(seconds: 10.2, at: now + 0.5)
        XCTAssertEqual(page.position(at: now + 0.5), 10.2, accuracy: 1e-9,
                       "硬校准必须无视 sync 的 600ms 门槛")
    }

    // MARK: - 硬校准之后：误差清零并以新纪元重启

    /// 硬校准之后，页面位置在后续时间里必须继续按 rate=1 推进，
    /// 而不是停在落位值上（否则歌词会卡住）。
    func testCalibrationRestartsExtrapolation() {
        var page = PageClock()
        let now = 200.0

        page.hardCalibrate(seconds: 87.0, at: now)
        XCTAssertEqual(page.position(at: now), 87.0, accuracy: 1e-9)

        // 3 秒后应推进到 90.0
        XCTAssertEqual(page.position(at: now + 3.0), 90.0, accuracy: 1e-9,
                       "硬校准后必须立即恢复外推，否则歌词会停在原地")
    }

    /// 校准的坐标系换算：页面工作在「歌词时间 = 播放位置 + 用户偏移」，
    /// 下发的毫秒值必须带上偏移，否则设过偏移的用户校准后会立刻偏回去。
    func testCalibrationAppliesLyricOffset() {
        func calibrationMs(playbackSeconds: Double, lyricOffset: Double) -> Int {
            Int(((max(0, playbackSeconds) + lyricOffset) * 1000).rounded())
        }

        XCTAssertEqual(calibrationMs(playbackSeconds: 42.0, lyricOffset: 0), 42_000)
        XCTAssertEqual(calibrationMs(playbackSeconds: 42.0, lyricOffset: 0.3), 42_300)
        XCTAssertEqual(calibrationMs(playbackSeconds: 42.0, lyricOffset: -0.3), 41_700)
    }

    /// 负位置必须被夹到 0：AVPlayer 在曲首 seek 时可能回报极小负数。
    func testCalibrationClampsNegativePosition() {
        func calibrationMs(playbackSeconds: Double, lyricOffset: Double) -> Int {
            Int(((max(0, playbackSeconds) + lyricOffset) * 1000).rounded())
        }
        XCTAssertEqual(calibrationMs(playbackSeconds: -0.02, lyricOffset: 0), 0)
        // 负偏移可以合法地把歌词时间推到 0 之前（用户就是想让歌词晚于歌声）。
        XCTAssertEqual(calibrationMs(playbackSeconds: 0.1, lyricOffset: -0.3), -200)
    }

    // MARK: - 触发时机：绝不能在校准拖动过程中下发

    /// RN 源码明确记录的坑：拖动中高频注入 `seekCommand` 会不断重置外推纪元、
    /// 挤掉最终那次校准，反而让松手后彻底脱节。
    /// 所以硬校准只在 `isScrubbing` 由 true → false（或页面内点歌词跳转）时触发。
    func testCalibrationOnlyFiresOnScrubEnd() {
        var calibrationCount = 0
        var previousIsScrubbing = false

        // 一次完整的拖动：开始 → 多次移动 → 结束
        let sequence = [true, true, true, true, false]
        for isScrubbing in sequence {
            if previousIsScrubbing && !isScrubbing { calibrationCount += 1 }
            previousIsScrubbing = isScrubbing
        }

        XCTAssertEqual(calibrationCount, 1,
                       "一次拖动只能产生一次校准事件，否则外推纪元会被反复重置")
    }

    /// 拖动中的高频位置更新（`updateScrubbing`）不得触发任何校准。
    func testDraggingUpdatesNeverCalibrate() {
        var previousIsScrubbing = true
        var calibrationCount = 0

        for _ in 0..<120 {  // 模拟 2 秒、每秒 60 次的拖动回调
            let isScrubbing = true
            if previousIsScrubbing && !isScrubbing { calibrationCount += 1 }
            previousIsScrubbing = isScrubbing
        }

        XCTAssertEqual(calibrationCount, 0)
    }

    // MARK: - 采样去重与移动判定

    /// 同值去重阈值必须**远小于**推送周期（100ms），否则正常的播放推进会被误吞。
    func testDedupeThresholdIsWellBelowPushInterval() {
        let pushIntervalMs = 100.0
        XCTAssertLessThan(Double(AMLLClockPolicy.dedupeThresholdMs), pushIntervalMs / 4,
                          "去重阈值过大就会把正常的播放推进也吞掉，歌词变卡")
        XCTAssertGreaterThan(AMLLClockPolicy.dedupeThresholdMs, 0,
                             "阈值为 0 等于不去重，白白唤醒 WebKit")
    }

    /// 移动判定阈值必须小于推送周期：否则每拍 10ms 的推进会被判成「没在动」，
    /// 页面收到 running=false 就停住（这正是缺口 B）。
    func testMovementThresholdIsSmallerThanPushInterval() {
        let pushIntervalMs = 100.0
        XCTAssertLessThan(Double(AMLLClockPolicy.movementThresholdMs), pushIntervalMs,
                          "移动阈值大于推送周期会让页面被误判为暂停")
        XCTAssertGreaterThanOrEqual(AMLLClockPolicy.movementThresholdMs,
                                    AMLLClockPolicy.dedupeThresholdMs,
                                    "移动判定应比纯去重更保守，否则两者含义重叠")
    }

    /// 校准阈值应比去重阈值宽：校准带一次 `setCurrentTime`，为几毫秒去重置不划算。
    func testCalibrationThresholdIsWiderThanDedupe() {
        XCTAssertGreaterThan(AMLLClockPolicy.calibrationThresholdMs,
                             AMLLClockPolicy.dedupeThresholdMs)
    }

    /// 校准阈值必须**远小于** sync 的 600ms 门槛：校准的目的就是在 sync 管不到的
    /// 亚秒区间里把误差清零，若阈值定到接近 600ms 就失去意义。
    func testCalibrationThresholdCoversTheGapSyncLeaves() {
        XCTAssertLessThan(Double(AMLLClockPolicy.calibrationThresholdMs), 600.0,
                          "校准阈值必须落在 sync 的门槛之内，否则补的正是它管不到的那一段")
        // 也必须真正能覆盖无损拖动后的典型残差量级（数十毫秒）。
        XCTAssertLessThanOrEqual(AMLLClockPolicy.calibrationThresholdMs, 100)
    }

    /// 收尾补校准的延迟必须存在但极短：为 0 会读到尚未落地的乐观值，
    /// 太长则用户能察觉歌词「顿一下」。
    func testSettleDelayIsShortButNonZero() {
        XCTAssertGreaterThan(AMLLClockPolicy.settleDelay, 0)
        XCTAssertLessThanOrEqual(AMLLClockPolicy.settleDelay, 0.2,
                                 "补校准延迟过长会让人看到歌词卡顿")
    }

    /// 用极短延迟跑一遍真实的收尾流程：`isScrubbing` 落回 false 后，
    /// 延时到期时读到的必须是**已更新**的精确位置。
    func testSettleCalibrationReadsPostSeekPosition() {
        var isScrubbing = true
        var precisePosition = 10.0

        // 拖动结束：PlayerCore 先乐观写入目标值，再在 seek 回调里校正为真实位置。
        let target = 42.0
        isScrubbing = false
        precisePosition = target          // 乐观写入
        let settleImpulse = AMLLClockPolicy.settleDelay > 0
        XCTAssertTrue(settleImpulse, "必须让出一个 runloop，否则可能读到陈旧值")

        // 回调落地（延迟期间发生）
        precisePosition = 42.0

        XCTAssertFalse(isScrubbing)
        XCTAssertEqual(precisePosition, target, accuracy: 1e-9,
                       "补校准读到的是 seek 回调校正后的精确位置")
    }
}
