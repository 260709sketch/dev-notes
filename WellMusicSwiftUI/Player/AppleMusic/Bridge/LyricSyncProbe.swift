import Foundation

/// 歌词同步探针：把「歌词页此刻在用的时钟」和「播放器此刻的位置」放到同一个屏幕上。
///
/// ## 它回答的问题
///
/// 「歌词和人声对不上」只有两种根源，一个数字就能分辨：
/// * **页面时钟 ≠ 播放器位置**（Δ 大）→ 时钟链路还有 bug，改代码就能修；
/// * **页面时钟 == 播放器位置**（Δ ≈ 0）但耳朵听着不齐 → `AVPlayer.currentTime()`
///   本身和可闻音频有偏差，代码层面无解，只有换内核一条路。
///
/// 所以这个数字是「要不要换 MPV」的**判据**，不是又一个盲试的旋钮。
///
/// ## 数据来源
///
/// * 页面侧：`AMLLLyricsPage.html` 的 rAF 循环每 250ms 回报
///   `Bp(now)`（歌词页当前时钟，含外推）；
/// * 播放器侧：收到回报的同一刻读 `PlayerCore.playerPosition`。
/// 两者相差一个 postMessage 往返（约 1–5ms），可忽略。
///
/// ## 性能
///
/// 刻意**不用** `@Published` / Combine：探针数据 4Hz 更新，任何订阅都会让
/// 挂它的视图树跟着重算。这里只存值，由显示端自己按需拉取（TimelineView）。
@MainActor
final class LyricSyncProbe {
    static let shared = LyricSyncProbe()
    private init() {}

    struct Sample {
        /// 歌词页当前时钟（毫秒，歌词时间轴）
        var pageMs: Double = 0
        /// 最近一次推给页面的锚点（毫秒）
        var anchorMs: Double = 0
        /// 页面时钟是否在推进
        var pageRunning: Bool = false
        /// 收到回报那一刻的播放器位置（毫秒，播放时间轴）
        var playerMs: Double = 0
        /// 播放器位置换算到歌词时间轴（+净偏移）后的对照值（毫秒）
        var expectedMs: Double = 0
        /// pageMs − expectedMs：**端到端同步误差**。0 附近 = 链路无误差。
        var deltaMs: Double = 0
        /// 是否处于「seek 落地监测」空窗期（此时 Δ 无意义，显示为「落地中」）
        var awaitingLanding: Bool = false
        /// 采样时刻（用于显示端判断数据新旧）
        var timestamp: TimeInterval = 0
    }

    private(set) var sample = Sample()

    /// 由 `AMLLWebLyricsView.Coordinator` 在收到页面回报时调用。
    func ingest(pageMs: Double, anchorMs: Double, pageRunning: Bool, lyricShift: TimeInterval) {
        let core = PlayerCore.shared
        let playerMs = core.playerPosition
        let expected = playerMs + lyricShift
        var s = Sample()
        s.pageMs = pageMs
        s.anchorMs = anchorMs
        s.pageRunning = pageRunning
        s.playerMs = playerMs * 1000
        s.expectedMs = expected * 1000
        s.deltaMs = pageMs - expected * 1000
        s.awaitingLanding = core.isAwaitingSeekLanding
        s.timestamp = Date().timeIntervalSinceReferenceDate
        sample = s
    }
}
