import Foundation

/// 播放地址解析器：本地文件直连，网络歌曲按平台 API 解析
final class MusicURLResolver {
    static let shared = MusicURLResolver()

    /// 解析播放地址（带缓存：失败不缓存，成功缓存到 item.playURL）
    func resolvePlayURL(for item: MusicItem, highQuality: Bool) async throws -> String {
        // 本地文件
        if let local = item.localFilePath, !local.isEmpty {
            return URL(fileURLWithPath: local).absoluteString
        }
        // 已有可播放地址
        if let u = item.playURL, !u.isEmpty, !u.hasPrefix("__") {
            return u
        }
        return try await PlatformSongResolver.shared.resolve(item: item, highQuality: highQuality)
    }
}

/// 平台播放地址解析入口
final class PlatformSongResolver {
    static let shared = PlatformSongResolver()

    func resolve(item: MusicItem, highQuality: Bool) async throws -> String {
        var url = ""
        switch item.source {
        case .qq:
            url = try await QQMusicAPI.shared.resolvePlayURL(item: item, highQuality: highQuality)
        case .netease:
            url = try await NeteaseMusicAPI.shared.resolvePlayURL(item: item, highQuality: highQuality)
        case .kugou:
            url = try await KugouMusicAPI.shared.resolvePlayURL(item: item, highQuality: highQuality)
        case .kuwo:
            url = try await KuwoMusicAPI.shared.resolvePlayURL(item: item, highQuality: highQuality)
        case .auto:
            // 自动：按来源依次尝试（网易云优先，与歌词来源逻辑一致）
            var lastError: Error = MusicURLResolverError.notResolved(.auto)
            for src in [MusicSource.netease, .qq, .kugou, .kuwo] {
                var candidate = item
                candidate.source = src
                do {
                    url = try await resolve(item: candidate, highQuality: highQuality)
                    if !url.isEmpty { return url }
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
        guard !url.isEmpty else { throw MusicURLResolverError.notResolved(item.source) }
        return url
    }
}

enum MusicURLResolverError: LocalizedError {
    case notResolved(MusicSource)

    var errorDescription: String? {
        switch self {
        case .notResolved(let src): return "无法解析 \(src.displayName) 的播放地址"
        }
    }
}