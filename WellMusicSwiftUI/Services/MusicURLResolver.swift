import Foundation

/// 播放解析结果：地址 + 播放所需请求头（自定义音源取链需要 Referer）。
struct ResolvedPlayback {
    var url: String
    var headers: [String: String]
    /// 提供地址的自定义音源名称；nil 表示走官方平台通道
    var fromCustomSource: String?
    /// 是否由非优先音源提供（自动换源）
    var isFallbackSource: Bool
}

/// 播放地址解析器：本地文件直连，自定义音源优先，其次各平台 API
final class MusicURLResolver {
    static let shared = MusicURLResolver()

    /// 解析播放信息（含请求头）。
    /// 顺序：本地文件 → 已缓存地址 → 自定义音源（激活时）→ 官方平台通道。
    /// 自定义音源取链失败会自动回退官方通道，保证仍能听歌。
    ///
    /// - Parameter preferOfficial: 跳过自定义音源、强制走官方平台通道。
    ///   用于「试听片段检测」：自定义源返回 15~30s 试听链接时重播完整版。
    func resolvePlayback(for item: MusicItem, quality: WellAudioQuality,
                         preferOfficial: Bool = false) async throws -> ResolvedPlayback {
        if let local = item.localFilePath, !local.isEmpty {
            return ResolvedPlayback(url: URL(fileURLWithPath: local).absoluteString,
                                    headers: [:], fromCustomSource: nil, isFallbackSource: false)
        }
        if let cached = item.playURL, !cached.isEmpty, !cached.hasPrefix("__") {
            // 缓存地址同样需要请求头（例如上一次由自定义音源取到的 CDN 直链），
            // 否则重放时会因缺少 Referer 而被 403。
            return ResolvedPlayback(url: cached,
                                    headers: WellLXPlaybackHeaders.requestHeaders(
                                        for: cached,
                                        platform: WellLXPlaybackHeaders.platformKey(for: item)),
                                    fromCustomSource: nil,
                                    isFallbackSource: false)
        }
        let hasActiveLXSource = await WellLXSourceStore.shared.hasActiveSource
        if hasActiveLXSource, !preferOfficial,
           let lx = await WellLXSourceStore.shared.resolvePlayback(for: item, quality: quality) {
            return ResolvedPlayback(url: lx.url,
                                    headers: lx.headers,
                                    fromCustomSource: lx.sourceName,
                                    isFallbackSource: lx.isFallback)
        }
        let url = try await PlatformSongResolver.shared.resolve(item: item, quality: quality)
        return ResolvedPlayback(url: url, headers: [:], fromCustomSource: nil, isFallbackSource: false)
    }

    /// 兼容旧签名：仅返回地址。
    func resolvePlayURL(for item: MusicItem, quality: WellAudioQuality) async throws -> String {
        try await resolvePlayback(for: item, quality: quality).url
    }
}

/// 平台播放地址解析入口
final class PlatformSongResolver {
    static let shared = PlatformSongResolver()

    func resolve(item: MusicItem, quality: WellAudioQuality) async throws -> String {
        var url = ""
        switch item.source {
        case .qq:
            url = try await QQMusicAPI.shared.resolvePlayURL(item: item, quality: quality)
        case .netease:
            url = try await NeteaseMusicAPI.shared.resolvePlayURL(item: item, quality: quality)
        case .kugou:
            url = try await KugouMusicAPI.shared.resolvePlayURL(item: item, quality: quality)
        case .kuwo:
            url = try await KuwoMusicAPI.shared.resolvePlayURL(item: item, quality: quality)
        case .lx:
            // 自定义音源条目：还原成底层平台条目后按平台解析
            let unwrapped = item.unwrappedFromCustomSource()
            url = try await resolve(item: unwrapped, quality: quality)
        case .auto:
            // 自动：按来源依次尝试（网易云优先，与歌词来源逻辑一致）
            var lastError: Error = MusicURLResolverError.notResolved(.auto)
            for src in [MusicSource.netease, .qq, .kugou, .kuwo] {
                var candidate = item
                candidate.source = src
                do {
                    url = try await resolve(item: candidate, quality: quality)
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