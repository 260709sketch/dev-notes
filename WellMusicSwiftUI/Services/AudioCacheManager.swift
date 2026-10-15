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

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    private let maxBytes: Int64 = 1_500_000_000

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
                self.enforceLimitIfNeeded()
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

    // MARK: - 内部

    private func cacheKey(for item: MusicItem) -> String {
        Data(item.keyOf.utf8).md5Hex()
    }

    private func fileURL(for item: MusicItem) -> URL {
        directory.appendingPathComponent(cacheKey(for: item) + ".audio")
    }

    /// 超出容量上限时按修改时间（最后访问/写入）从旧到新淘汰。
    private func enforceLimitIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
