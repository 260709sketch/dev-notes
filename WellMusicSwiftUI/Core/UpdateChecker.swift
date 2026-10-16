import Foundation

/// 检查更新：从 GitHub 仓库读取最新版本，与本地版本比对。
///
/// 用户 2026-10-16 问题16：设置 → 关于 新增「检查更新」等更新机制，
/// 「后续会加入 github 仓库来拉取更新」。
///
/// 这里按「先看 Release、再看 Tag」的顺序取远端版本（两种发布方式都支持）：
///   1. `GET /repos/{repo}/releases/latest` → `tag_name` / `name` / `body` / `html_url`
///   2. 仓库还没发过 Release 时退回 `GET /repos/{repo}/tags?per_page=1`
/// 远端版本比本地新 → 返回更新信息（含发布页地址，点一下即可下载）；
/// 相等或更旧 → 「已是最新版本」；网络/仓库不可达 → 明确报错，不假装成功。
///
/// 仓库地址可通过 `wellmusic.update.repo`（`owner/name`）覆盖，
/// 这样以后换成正式仓库不需要改代码。
enum UpdateChecker {

    /// 更新仓库（`owner/name`）的设置键。
    static let repoKey = "wellmusic.update.repo"

    /// 默认仓库：项目的构建仓库（CI 在这里产出安装包）。
    static let defaultRepo = "260709sketch/dev-notes"

    static var repo: String {
        let stored = (UserDefaults.standard.string(forKey: repoKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? defaultRepo : stored
    }

    /// 当前版本 / 构建号（Info.plist 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`）。
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    static var currentBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }

    /// 应用名（关于页展示用；与首页图标下的名字一致）。
    static let appName = "Well Music"

    struct UpdateInfo {
        var version: String
        var title: String
        var notes: String
        var pageURL: URL?
    }

    enum CheckResult {
        case upToDate(remote: String)
        case newer(UpdateInfo)
        case failed(String)
    }

    /// 执行一次检查。不做本地缓存 —— 更新检查是用户主动点的，必须反映当下状态。
    static func check() async -> CheckResult {
        let path = "/repos/\(repo)"
        // 先看 Release，再退回 Tag（不要写成 `await a() ?? await b()`：
        // `??` 右侧是同步 autoclosure，塞不进 async 调用）
        var latest = await fetchLatestRelease(path: path)
        if latest == nil { latest = await fetchLatestTag(path: path) }
        guard let latest else {
            return .failed("无法访问更新仓库（\(repo)），请检查网络后重试")
        }
        let remote = latest.version
        guard !remote.isEmpty else { return .failed("更新仓库没有可用的版本信息") }
        if compare(remote, currentVersion) > 0 {
            return .newer(latest)
        }
        return .upToDate(remote: remote)
    }

    // MARK: 远端读取

    private static func fetchLatestRelease(path: String) async -> UpdateInfo? {
        guard let data = try? await NetworkClient.shared.get(
            "https://api.github.com\(path)/releases/latest",
            headers: ["Accept": "application/vnd.github+json"]
        ).data else { return nil }
        guard let object = NetworkClient.jsonObject(data),
              let tag = object["tag_name"] as? String, !tag.isEmpty else { return nil }
        return UpdateInfo(
            version: tag,
            title: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            notes: (object["body"] as? String) ?? "",
            pageURL: (object["html_url"] as? String).flatMap(URL.init(string:))
        )
    }

    private static func fetchLatestTag(path: String) async -> UpdateInfo? {
        guard let data = try? await NetworkClient.shared.get(
            "https://api.github.com\(path)/tags?per_page=1",
            headers: ["Accept": "application/vnd.github+json"]
        ).data else { return nil }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = list.first,
              let name = first["name"] as? String, !name.isEmpty else { return nil }
        return UpdateInfo(version: name, title: name, notes: "", pageURL: nil)
    }

    // MARK: 版本比较

    /// 版本号比较：只比数字段（`v1.2.3` / `1.2` / `1.2.3-beta` 都能吃）。
    ///
    /// 返回 > 0 表示 `lhs` 比 `rhs` 新。逐段比较，段数不同时缺的按 0 算。
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = numericParts(lhs)
        let right = numericParts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b ? 1 : -1 }
        }
        return 0
    }

    private static func numericParts(_ text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
