import Foundation

/// 歌曲缓存：把播放过的歌曲音频**落盘**（Caches/audio-cache），
/// 再次播放同一首时直接读本地文件（秒开、省流量、离线可听）。
///
/// 设计（对齐参考项目歌曲缓存的语义，按本项目的解析链路精简）：
/// - **命中**：解析播放地址时优先查本地文件（`file://` 直读，无需请求头）；
/// - **写入**：解析成功、开始播放后**后台下载**（与播放并行，不阻塞、失败静默）；
/// - **容量**：上限 1.5GB，超出按「最后访问时间」淘汰最旧的文件（LRU）；
/// - **开关**：设置 → 播放 →「歌曲缓存」（默认开）。
@MainActor
final class AudioCacheManager {
    static let shared = AudioCacheManager()
    /// 设置键（默认开）
    static let enabledKey = "wellmusic.player.audioCacheEnabled"
    /// 缓存上限设置键（字节）
    static let limitKey = "wellmusic.player.audioCacheLimitBytes"
    /// 默认上限 1.5GB
    static let defaultLimitBytes: Int64 = 1_500_000_000

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    /// 用户选择的上限（设置 → 播放 → 缓存上限；默认 1.5GB）。
    static var byteLimit: Int64 {
        let stored = (UserDefaults.standard.object(forKey: limitKey) as? NSNumber)?.int64Value ?? 0
        return stored > 0 ? stored : defaultLimitBytes
    }

    /// 可选档位（设置页 Picker 用）。
    enum LimitOption: Int64, CaseIterable, Identifiable {
        case mb500 = 500_000_000
        case gb1 = 1_000_000_000
        case gb2 = 2_000_000_000
        case gb4 = 4_000_000_000
        case gb8 = 8_000_000_000

        var id: Int64 { rawValue }
        var displayName: String {
            switch self {
            case .mb500: return "500 MB"
            case .gb1: return "1 GB"
            case .gb2: return "2 GB"
            case .gb4: return "4 GB"
            case .gb8: return "8 GB"
            }
        }
    }

    private var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("audio-cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 正在下载的 key（去重：同一首歌不重复下载）。
    private var inflight: Set<String> = []

    private init() {}

    // MARK: - 命中

    /// 本地缓存文件（命中返回；同时刷新修改时间用于 LRU）。
    func cachedFileURL(for item: MusicItem) -> URL? {
        guard Self.isEnabled else { return nil }
        let url = fileURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: url.path)
        return url
    }

    // MARK: - 写入（后台下载）

    /// 后台缓存一首歌的音频（与播放并行；已存在 / 下载中 / file:// 一律跳过）。
    func cacheIfNeeded(item: MusicItem, remoteURL: String, headers: [String: String]) {
        guard Self.isEnabled,
              !remoteURL.isEmpty,
              !remoteURL.hasPrefix("file://"),
              let remote = URL(string: remoteURL) else { return }
        let key = cacheKey(for: item)
        let destination = fileURL(for: item)
        guard !inflight.contains(key),
              !FileManager.default.fileExists(atPath: destination.path) else { return }
        inflight.insert(key)

        var request = URLRequest(url: remote)
        request.timeoutInterval = 90
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        URLSession.shared.downloadTask(with: request) { tempURL, _, _ in
            Task { @MainActor in
                defer { self.inflight.remove(key) }
                guard let tempURL else { return }
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: tempURL, to: destination)
                // ★ 2026-10-16 问题15：容量检查改成**总预算**（歌曲 + 图片 + 歌手主页缓存合计），
                //   不能再只盯着歌曲缓存自己那点体积。
                CacheBudget.enforceIfNeeded()
            }
        }.resume()
    }

    // MARK: - 管理（存储页）

    /// 缓存占用字节数。
    func totalSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// 清空全部歌曲缓存。
    func clear() {
        inflight.removeAll()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// 缓存文件清单（路径 / 大小 / 最后访问时间），交给 `CacheBudget` 做**总预算**淘汰。
    ///
    /// ★ 2026-10-16 问题15：以前这里自己算自己的上限，图片缓存完全不受限，
    ///   所以「设置了 4G 依旧超过 4G」。现在统一由 `CacheBudget` 按三类缓存全局 LRU 淘汰。
    func diskEntries() -> [CacheFileEntry] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        return files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return CacheFileEntry(url: file,
                                  size: Int64(values.fileSize ?? 0),
                                  date: values.contentModificationDate ?? .distantPast,
                                  kind: .audio)
        }
    }

    // MARK: - 内部

    private func cacheKey(for item: MusicItem) -> String {
        Data(item.keyOf.utf8).md5Hex()
    }

    private func fileURL(for item: MusicItem) -> URL {
        directory.appendingPathComponent(cacheKey(for: item) + ".audio")
    }

    /// 立即执行一次容量检查（用户改上限时调用）—— 走**总预算**（含图片/歌手主页缓存）。
    func enforceLimitNow() {
        CacheBudget.enforceIfNeeded(force: true)
    }
}
