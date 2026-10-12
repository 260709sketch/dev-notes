import Foundation

/// 播放器启动/卡死自检日志。
///
/// 用途：用户反馈「打开播放器卡死」时，接上电脑看控制台就能**一步定位**卡在哪一环。
/// 设计原则：
///   * **零成本**：只调用 `print`，不参与 SwiftUI 依赖追踪，不会让任何视图多算一次。
///   * **可关闭**：`enabled` 跟随 `UserDefaults` 的 `wellmusic.player.diagnostics`。
///     默认 **开启**（DEBUG 与 Release 都开），排查期就是要能看见；
///     确认稳定后可在设置里关掉。
///   * **带时间戳差**：`tick(_:)` 记录相对启动的时间，直接看出哪一步花了多久 ——
///     卡死问题里「哪一步慢」比「哪一步错」更有价值。
///
/// 读日志的方式（Mac 上）：Xcode → Devices and Simulators → 选设备 → Open Console，
/// 过滤关键字 `[Player]` 即可。
///
/// 用 `print` 而非 `os.Logger`：`os_log` 的字符串插值在部分 Xcode/iOS 组合下对
/// `privacy` 参数支持不稳定，排查阶段不值得为一条日志赌编译稳定性。
/// `print` 在 Xcode 控制台与 `idevicesyslog` 下都直接可见。
enum PlayerDiag {
    /// 诊断开关。默认开；`wellmusic.player.diagnostics = false` 可关。
    static var enabled: Bool {
        // 没写过这个 key 时视为开启。
        if UserDefaults.standard.object(forKey: "wellmusic.player.diagnostics") == nil { return true }
        return UserDefaults.standard.bool(forKey: "wellmusic.player.diagnostics")
    }

    private static let processStart = CFAbsoluteTimeGetCurrent()

    /// 打一条带相对时间戳的日志。
    ///
    /// - Parameter message: 诊断信息。**不要**拼入大对象（歌词全文等），
    ///   这里只适合短字符串；需要细节请只打数量、哈希、长度。
    static func log(_ message: String) {
        guard enabled else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - processStart) * 1000
        print(String(format: "[Player] +%.0fms  %@", ms, message))
    }

    /// 记录「进入某一段」并返回一个结束回调，用于测量耗时。
    ///
    /// 用法：
    /// ```
    /// let done = PlayerDiag.begin("加载歌词页")
    /// ...
    /// done()
    /// ```
    static func begin(_ stage: String) -> () -> Void {
        guard enabled else { return {} }
        let start = CFAbsoluteTimeGetCurrent()
        log("▶ 开始：\(stage)")
        return {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            log(String(format: "■ 结束：%@（耗时 %.0fms）", stage, ms))
        }
    }

    /// 单点标记，比 `log` 更短。
    static func tick(_ stage: String) {
        log("• \(stage)")
    }
}
