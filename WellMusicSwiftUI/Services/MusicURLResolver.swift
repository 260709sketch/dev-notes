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

/// 播放地址解析器：本地文件直连 → 已缓存地址 → LX 自定义音源。
///
/// ## 设计原则（2026-10-13 定案）
///
/// **所有播放一律走 LX 自定义音源解析**，不再回退官方平台通道。
/// LX 音源不存在「试听片段」概念（试听是旧官方通道的产物），所以解析到
/// 什么就播什么。LX 未激活或解析失败时直接抛错，由播放器提示用户，
/// 绝不静默回退官方 —— 避免用户听到与预期不符的音源。
final class MusicURLResolver {
    static let shared = MusicURLResolver()

    /// 「内置音源」开关（设置 → 自定义音源；默认关）。
    /// 开启后：未导入自定义音源、或全部音源解析失败时，用官方平台通道兜底播放。
    static let builtinSourceKey = "wellmusic.player.builtinSourceFallback"

    /// 解析播放信息（含请求头）。
    /// 顺序：本地文件 → 歌曲缓存 → 已缓存地址 → LX 自定义音源 → 内置音源（开关开启时兜底）。
    /// 解析成功后自动触发**后台歌曲缓存**（设置 → 播放 → 歌曲缓存）。
    func resolvePlayback(for item: MusicItem, quality: WellAudioQuality) async throws -> ResolvedPlayback {
        let result = try await resolvePlaybackUncached(for: item, quality: quality)
        await AudioCacheManager.shared.cacheIfNeeded(item: item,
                                                     remoteURL: result.url,
                                                     headers: result.headers)
        return result
    }

    private func resolvePlaybackUncached(for item: MusicItem, quality: WellAudioQuality) async throws -> ResolvedPlayback {
        if let local = item.localFilePath, !local.isEmpty {
            return ResolvedPlayback(url: URL(fileURLWithPath: local).absoluteString,
                                    headers: [:], fromCustomSource: nil, isFallbackSource: false)
        }
        // ★ 歌曲缓存命中：直接读本地文件（秒开、无需请求头）。
        if let cachedAudio = await AudioCacheManager.shared.cachedFileURL(for: item) {
            return ResolvedPlayback(url: cachedAudio.absoluteString,
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
        let hasLX = await WellLXSourceStore.shared.hasActiveSource
        let builtinEnabled = UserDefaults.standard.bool(forKey: Self.builtinSourceKey)

        // ★ 有 LX 音源：优先走 LX（激活且有可用脚本时）。
        if hasLX,
           let lx = await WellLXSourceStore.shared.resolvePlayback(for: item, quality: quality) {
            return ResolvedPlayback(url: lx.url,
                                    headers: lx.headers,
                                    fromCustomSource: lx.sourceName,
                                    isFallbackSource: lx.isFallback)
        }
        // ★ 内置音源兜底（用户 2026-10-15）：官方平台通道 + 提示。
        if builtinEnabled {
            return try await resolveViaBuiltinSource(item: item, quality: quality)
        }
        // 无 LX 且未开内置音源 → 按原语义报错。
        throw hasLX ? MusicURLResolverError.lxResolveFailed : MusicURLResolverError.lxSourceUnavailable
    }

    /// 内置音源：**解锁源优先**（自动匹配酷狗/酷我完整音频），
    /// 失败再回退官方平台通道（可能受试听限制）；成功后 Toast 提示。
    private func resolveViaBuiltinSource(item: MusicItem, quality: WellAudioQuality) async throws -> ResolvedPlayback {
        if let unlocked = await BuiltinAudioSource.resolve(item: item, quality: quality) {
            await ToastCenter.shared.show("使用内置音源播放")
            return ResolvedPlayback(
                url: unlocked.url,
                headers: WellLXPlaybackHeaders.requestHeaders(
                    for: unlocked.url, platform: WellLXPlaybackHeaders.platformKey(for: item)),
                fromCustomSource: unlocked.sourceName,
                isFallbackSource: true)
        }
        // 解析源失败 → 官方通道（可能仅试听）：提示区分，便于用户理解「30 秒」的来源
        let url = try await PlatformSongResolver.shared.resolve(item: item, quality: quality)
        await ToastCenter.shared.show("内置音源解析失败，已用官方音源")
        return ResolvedPlayback(
            url: url,
            headers: WellLXPlaybackHeaders.requestHeaders(
                for: url, platform: WellLXPlaybackHeaders.platformKey(for: item)),
            fromCustomSource: "内置音源",
            isFallbackSource: true)
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
    /// LX 自定义音源未激活（所有播放必须走 LX，未激活即为不可播）
    case lxSourceUnavailable
    /// LX 自定义音源解析失败（限流 / 脚本返回空 / 该曲目无资源）
    case lxResolveFailed

    var errorDescription: String? {
        switch self {
        case .notResolved(let src): return "无法解析 \(src.displayName) 的播放地址"
        case .lxSourceUnavailable: return "请先在设置中启用自定义音源"
        case .lxResolveFailed: return "自定义音源解析失败，请稍后重试"
        }
    }
}