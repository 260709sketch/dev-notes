import Foundation

/// 全局「刷新闸门」：同一份数据在冷却时间内只允许重新拉取一次。
///
/// 用户 2026-10-16 问题22：「给所有界面新增缓存机制，比如进入歌单后回到我的页
/// 不会再次触发刷新；要能自动检测用户的频繁行为，频繁就限制刷新 —— 等几分钟
/// 结束后、或者重启 App 再刷新，不然容易造成性能损失。」
///
/// 实现就一件事：按 `key` 记下**上次真正发起刷新的时刻**，冷却期内直接拒绝。
/// 这不是数据缓存（数据仍由各页面自己的 `@State` 持有），只是**限流**：
/// 页面来回切换时不会反复打网络、反复重建列表，也就不会出现「退回来封面集体闪一下」。
///
/// 用法：
/// ```swift
/// guard RefreshGate.shared.allow("profile.content") else { return }
/// await fetch()
/// ```
/// * `allow` 放行时**顺手记下本次时间**，调用方不需要再调 `mark`。
/// * 用户主动触发的刷新（下拉刷新 / 点「重试」）以及登录态变化这类「必须立刻刷新」
///   的场景，先 `force(key)` 再拉，否则会被闸门挡掉。
final class RefreshGate {
    static let shared = RefreshGate()

    /// 默认冷却时长：5 分钟（用户原话「等几分钟」）。
    static let defaultCooldown: TimeInterval = 300

    private let lock = NSLock()
    private var stamps: [String: Date] = [:]

    private init() {}

    /// 是否放行本次刷新。放行时顺带记录时间。
    func allow(_ key: String, cooldown: TimeInterval = RefreshGate.defaultCooldown) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = stamps[key], now.timeIntervalSince(last) < cooldown { return false }
        stamps[key] = now
        return true
    }

    /// 清掉某个 key 的冷却记录（下一次 `allow` 必然放行）。
    ///
    /// 用于「用户主动刷新」与「登录态变化」——这类刷新不该被限流。
    func force(_ key: String) {
        lock.lock()
        stamps[key] = nil
        lock.unlock()
    }

    /// 当前是否处于冷却中（需要给用户提示时用）。
    func isCoolingDown(_ key: String, cooldown: TimeInterval = RefreshGate.defaultCooldown) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = stamps[key] else { return false }
        return Date().timeIntervalSince(last) < cooldown
    }

    /// 冷却中剩余秒数（无记录或已过冷却返回 0）。
    func remaining(_ key: String, cooldown: TimeInterval = RefreshGate.defaultCooldown) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let last = stamps[key] else { return 0 }
        return max(0, cooldown - Date().timeIntervalSince(last))
    }

    /// 整体失效（退出登录 / 切换账号等：「换个账号了，缓存的时间戳全部作废」）。
    func resetAll() {
        lock.lock()
        stamps.removeAll()
        lock.unlock()
    }
}
