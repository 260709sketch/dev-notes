import Foundation

/// 一个缓存文件（供总预算管理器做 LRU 淘汰）。
struct CacheFileEntry {
    enum Kind {
        case audio
        case image
        case artist
    }

    let url: URL
    let size: Int64
    /// 最后访问/写入时间（LRU 依据）
    let date: Date
    let kind: Kind
}

/// 缓存总预算：把**歌曲缓存 + 图片缓存 + 歌手主页缓存**合起来控制在用户设置的
/// 「缓存上限」之内（设置 → 存储 → 缓存上限）。
///
/// ★ 2026-10-16 用户问题15：「修复缓存上限仅是个摆设的问题 —— 设置了 4G 缓存，
///   缓存的歌曲和图片依旧超过 4G」。根因两条，都在这里修掉：
///   ① 上限以前**只作用在歌曲缓存**上（`AudioCacheManager` 自己算自己），
///      图片缓存完全没有上限，一路涨到把设备塞满；
///   ② 而且只在「一次歌曲下载完成」后检查，用户只刷图 / 改上限 / 冷启动都不触发。
///   现在：三类缓存**统一按最旧优先淘汰**，触发时机 = 每次写盘后（20 秒节流，
///   避免每存一张图就扫一遍目录）、冷启动、以及用户在设置里改上限时。
///
/// 口径说明：`缓存上限` = 上述三类缓存**合计**允许占用的磁盘空间。淘汰时
/// 「最旧的先死」（`date` 取最后访问时间，播过/看过的会不断刷新时间戳），
/// 所以常听常看的不会被删掉。
@MainActor
enum CacheBudget {

    /// 用户设置的上限（字节）。0 或未设置时用 `AudioCacheManager` 的默认值。
    static var limitBytes: Int64 { AudioCacheManager.byteLimit }

    /// 上次检查时间（节流用）。
    private static var lastCheck = Date.distantPast
    /// 自动检查的最小间隔（秒）。
    private static let minInterval: TimeInterval = 20
    /// 是否正在检查（避免并发重复扫描）。
    private static var running = false

    /// 写盘后调用（节流版）。
    static func enforceIfNeeded(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastCheck) < minInterval { return }
        lastCheck = now
        Task { await enforce() }
    }

    /// 立即执行一次预算检查（用户改上限 / 冷启动 / 用户手动清理时用）。
    static func enforce() async {
        guard !running else { return }
        running = true
        defer { running = false }

        let limit = limitBytes
        guard limit > 0 else { return }

        var entries = AudioCacheManager.shared.diskEntries()
        entries += WellImageCache.shared.diskEntries()
        entries += WellArtistHomeCache.shared.diskEntries()

        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }

        var evictedImageFiles = false
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > limit else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if entry.kind == .image { evictedImageFiles = true }
        }
        // 图片文件被删掉后，内存里的那份也要放掉 —— 否则图片仍在内存缓存里
        // 「看起来还在」，下次显示时既不落盘也不再回填，冷启动就全丢了。
        if evictedImageFiles {
            await WellImageCache.shared.dropMemoryCache()
        }
    }

    /// 三类缓存合计占用（存储页展示用）。
    static func totalUsage() async -> (audio: Int64, image: Int64, artist: Int64) {
        let audio = AudioCacheManager.shared.totalSize()
        let image = WellImageCache.shared.diskUsage()
        let artist = WellArtistHomeCache.shared.diskUsage()
        return (audio, image, artist)
    }
}
