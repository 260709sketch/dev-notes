import Foundation

/// 已登录的网易云账号。
///
/// 只保留界面上真正会用到的三项，不照搬接口返回的一大坨字段 ——
/// 以后要做「关注/粉丝数」之类再按需加。
struct NeteaseAccount: Codable, Equatable {
    var userId: Int
    var nickname: String
    var avatarURL: String?
}

/// 网易云登录态的唯一持有者。
///
/// 职责边界刻意分成两半：
///   * **凭据（Cookie）**：`cookieHeader` 是**线程安全的同步读**，网络层在任意线程
///     直接拿去当 `Cookie` 头发请求，不需要 `await` 到主线程；
///   * **账号信息**：`account` 是 `@Published`，登录卡片据此显示头像与昵称。
///
/// 为什么 Cookie 不放进 `@Published`：网易云的接口散落在 LX 脚本、歌词、播放地址等
/// 多处后台任务里，如果读个 Cookie 都要 `await MainActor` 一下，等于把所有请求
/// 都串到主线程上排队。用一个 `NSLock` 保护的小字典更直接，也不会误触发 UI 刷新。
final class NeteaseSession: ObservableObject, @unchecked Sendable {
    static let shared = NeteaseSession()

    private enum Keys {
        static let cookies = "wellmusic.netease.cookies"
        static let account = "wellmusic.netease.account"
    }

    /// 登录票据就存放在这个 Cookie 里 —— 它存在即视为「已登录」。
    private static let authCookie = "MUSIC_U"

    /// 网易云认这组「客户端标识」，缺了会在部分接口上被当成匿名浏览器请求。
    /// 与 kumone 一致地带上，属于接口约定而非实现细节。
    private static let clientIdentity = ["os": "pc", "appver": "3.1.17"]

    @Published private(set) var account: NeteaseAccount?

    private let lock = NSLock()
    private var cookieStorage: [String: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.cookies),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            cookieStorage = stored
        }
        if let data = UserDefaults.standard.data(forKey: Keys.account),
           let stored = try? JSONDecoder().decode(NeteaseAccount.self, from: data) {
            account = stored
        }
    }

    // MARK: 凭据读取（线程安全，可在任意线程调用）

    /// 是否已登录。
    var isLoggedIn: Bool { cookie(named: Self.authCookie) != nil }

    /// 拼好的 `Cookie` 头。登录后每个请求都要带上，否则拿到的是匿名数据。
    var cookieHeader: String {
        lock.lock()
        var all = cookieStorage
        lock.unlock()
        for (key, value) in Self.clientIdentity where all[key] == nil {
            all[key] = value
        }
        return all.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    func cookie(named name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cookieStorage[name]
    }

    // MARK: 凭据写入

    /// 合并一批 Cookie 并落盘。
    func merge(cookies new: [String: String]) {
        let cleaned = new.filter { !$0.value.isEmpty && $0.value != "\"\"" }
        guard !cleaned.isEmpty else { return }
        lock.lock()
        for (key, value) in cleaned { cookieStorage[key] = value }
        let snapshot = cookieStorage
        lock.unlock()
        persist(snapshot)
    }

    /// 解析一坨原始 Cookie 文本。
    ///
    /// 同时兼容浏览器的 `; ` 分隔与网易云登录响应里的 `;;` 分隔 ——
    /// 按单个 `;` 切分时 `;;` 只会产生空串，直接被过滤掉，两种都能吃。
    func ingest(cookieString raw: String) {
        var parsed: [String: String] = [:]
        for piece in raw.components(separatedBy: ";") {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            parsed[String(name)] = value
        }
        merge(cookies: parsed)
    }

    /// 从登录响应的 `Set-Cookie` 头里吸收票据。
    func absorb(setCookieHeaders: [String]) {
        var parsed: [String: String] = [:]
        for header in setCookieHeaders {
            // 一个 Set-Cookie 头可能被折叠成多行（见 NetworkClient.headerFields）
            for line in header.components(separatedBy: "\n") {
                guard let firstSegment = line.components(separatedBy: ";").first,
                      let eq = firstSegment.firstIndex(of: "=") else { continue }
                let name = firstSegment[..<eq].trimmingCharacters(in: .whitespaces)
                let value = firstSegment[firstSegment.index(after: eq)...]
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !value.isEmpty, value != "\"\"" else { continue }
                parsed[String(name)] = String(value)
            }
        }
        merge(cookies: parsed)
    }

    /// 退出登录：只清登录票据，保留其它无关 Cookie。
    @MainActor
    func clearAuth() {
        lock.lock()
        cookieStorage.removeValue(forKey: Self.authCookie)
        cookieStorage.removeValue(forKey: "__csrf")
        let snapshot = cookieStorage
        lock.unlock()
        persist(snapshot)
        account = nil
        UserDefaults.standard.removeObject(forKey: Keys.account)
    }

    // MARK: 账号信息

    /// 拉一次账号信息。返回是否处于有效登录态。
    ///
    /// 登录成功后、以及每次冷启动进入「我的」页时都会调一次 ——
    /// 它同时也是**校验 Cookie 是否还有效**的手段（过期会返回未登录错误）。
    @MainActor
    @discardableResult
    func refreshAccount() async -> Bool {
        guard isLoggedIn else {
            account = nil
            return false
        }
        guard let fetched = try? await NeteaseMusicAPI.shared.userAccount() else {
            // 网络抖动不该直接把用户踢下线：保留本地缓存，界面照常显示
            return account != nil
        }
        account = fetched
        if let data = try? JSONEncoder().encode(fetched) {
            UserDefaults.standard.set(data, forKey: Keys.account)
        }
        return true
    }

    // MARK: 落盘

    private func persist(_ snapshot: [String: String]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Keys.cookies)
    }
}
