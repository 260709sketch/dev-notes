import Foundation
import QuartzCore

/// 歌词时钟：**单调外推 + 异常报告抑制**。
///
/// ## 为什么需要它（这是「拖完进度条歌词慢几秒」的最终根因）
///
/// 前面几版一直把 `AVPlayer.currentTime()` 当作歌词时钟的直接来源，并试图
/// 用「落地监测 / 冻结 / 硬锚」去修补它的时序问题。但实测证明：

/// **seek 之后，AVPlayer 报告的位置本身就可能与真正听到的声音不一致。**
///
/// 远端无损（FLAC / Hi-Res）在 seek 后要重建时间基准，这期间：
/// * 有时 `currentTime()` **冻结在 seek 目标上好几秒**（音频其实已经在正常播放）
///   → 歌词被这个假值钉住 → **歌词慢几秒**；
/// * 有时它**先跳到目标、音频后到**
///   → 歌词被拖着往前跑 → **歌词快好几段**。
///
/// 两种方向都实测出现过，且正常播放时完全正常 —— 因为那时报告值是诚实的。
/// 也就是说：**问题不在歌词页，在这个报告值不可信。**
///
/// ## 做法：让歌词时钟自己走，只在报告可信时才对齐
///
/// * 时钟的主推进是**墙上时间（1x）**，不再依赖播放器的报告；
/// * 报告值与自己的外推值之差落在**死区**（±0.30s）内 → 采信报告（消除长期漂移）；
/// * 报告值**领先**死区 → 认为播放器追上了真实位置 → 采信；
/// * 报告值**落后**死区 → 视为「冻结/陈旧报告」→ **丢弃**，继续自己走；
///   只有持续落后超过 `maxIgnoreBehind` 秒才采信（避免真的回退时永久分叉）；
/// * 音频不在渲染（缓冲中 / 暂停）→ 时钟**停住**，不空转。
///
/// 于是：正常播放 → 报告 ≈ 外推 → 保持锁定，和以前一样精确；
/// seek 后 → 报告即使冻结，时钟照样跟着音乐走 → **不再慢几秒**。
///
/// 刻意做成**纯逻辑 + 可注入时间源**，便于单元测试锁死这些契约。
final class LyricClock {

    // MARK: 可调参数（测试会直接引用这些常量）

    /// 死区（秒）：报告与外推之差在此范围内即采信报告，用于消除长期漂移。
    static let deadZone: TimeInterval = 0.30
    /// 报告持续落后死区时，最长容忍时长（秒）；超过则采信报告，避免永久分叉。
    static let maxIgnoreBehind: TimeInterval = 2.5

    // MARK: 状态

    /// 时钟当前值（秒，媒体时间轴）。有未结算的墙上时间时会由 `current` 补齐。
    private var value: TimeInterval = 0
    /// `value` 对应的墙上时刻。
    private var wall: TimeInterval = 0
    /// 是否处于停住状态（暂停 / 缓冲中）：停住时墙上时间不累积。
    private var stalled = true
    /// 开始"丢弃落后报告"的墙上时刻（nil = 当前没有在丢弃）。
    private var ignoringBehindSince: TimeInterval?

    private let now: () -> TimeInterval

    /// - Parameter now: 时间源（默认 `CACurrentMediaTime`，单调、不受系统时间调整影响）。
    init(now: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        self.now = now
        self.wall = now()
    }

    // MARK: 对外

    /// 时钟当前值（秒）。停住时就是冻结值；否则是「最后结算值 + 已流逝的墙上时间」。
    var current: TimeInterval {
        guard !stalled else { return max(0, value) }
        return max(0, value + max(0, now() - wall))
    }

    /// 是否已停住（暂停 / 缓冲中）。
    var isStalled: Bool { stalled }

    /// **硬锚**：跳转到一个确定的位置（拖动松手、点歌词、切歌、seek 落地）。
    ///
    /// 锚定后时钟从该位置按 1x 自己走，不再等待播放器的报告。
    func reset(to time: TimeInterval) {
        let t = now()
        value = max(0, time)
        wall = t
        stalled = false
        ignoringBehindSince = nil
    }

    /// **停住**：音频没有在渲染（暂停 / 缓冲中）。墙上时间不再累积，时钟停在当前值。
    func hold() {
        guard !stalled else { return }
        value = current
        wall = now()
        stalled = true
        ignoringBehindSince = nil
    }

    /// 结算一次：推进墙上时间，并按上面的规则决定是否采信播放器的报告值。
    ///
    /// - Parameters:
    ///   - reported: `AVPlayer.currentTime()`（可能冻结、可能跳变，不可尽信）。
    ///   - rendering: 音频此刻是否真的在渲染（`isRenderingAudio`）。
    /// - Returns: 结算后的时钟值（秒）。
    @discardableResult
    func tick(reported: TimeInterval, rendering: Bool) -> TimeInterval {
        let t = now()

        guard rendering else {
            // 音频没在走：时钟停住
            if !stalled { value = current; stalled = true }
            wall = t
            ignoringBehindSince = nil
            return max(0, value)
        }

        // 1x 推进（若刚从停住态恢复，本次只重置纪元，不补时间）
        if stalled {
            stalled = false
            wall = t
        } else {
            value += max(0, t - wall)
            wall = t
        }

        guard reported.isFinite, reported >= 0 else { return max(0, value) }

        let error = reported - value
        if abs(error) <= Self.deadZone {
            // 死区内：直接对齐，消除长期漂移
            value = reported
            ignoringBehindSince = nil
        } else if error > 0 {
            // 报告领先：播放器追上了真实位置（或确实向前跳了），采信
            value = reported
            ignoringBehindSince = nil
        } else {
            // 报告落后：可能是「冻结 / 陈旧」的报告 —— 丢弃，继续自己走。
            // 但持续落后过久则采信一次，避免真的回退时永久分叉。
            if let since = ignoringBehindSince {
                if t - since > Self.maxIgnoreBehind {
                    value = reported
                    ignoringBehindSince = nil
                }
            } else {
                ignoringBehindSince = t
            }
        }
        return max(0, value)
    }
}
