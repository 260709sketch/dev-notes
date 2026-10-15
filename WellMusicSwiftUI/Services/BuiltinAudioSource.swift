import Foundation

/// 内置音源（歌曲解析）：自动匹配第三方解析源，拿**完整音频**（含 320k 高码率）。
///
/// 通道：GD 音乐 API（`music-api.gdstudio.xyz`，按平台映射 source + 歌曲 id 直取）。
/// - 网易云 / 自定义音源：source=netease（用网易云歌曲 id）
/// - QQ：source=tencent（用 songmid）
/// - 酷狗：source=kugou（用 hash）/ 酷我：source=kuwo（用 rid）
///
/// 与 RN 版 `helpers/unblockSources.ts`（内置兜底音源）对照：同为
/// 「Pyncmd（本 API）→ 酷狗 trackercdn」两级；酷狗级实测已失效（status=2），
/// 故本项目只保留本通道 + 官方兜底。
///
/// 说明（用户 2026-10-15）：
/// - 参考项目的「黑解」通道（酷狗 trackercdn v2 / 酷我 anti.s）实测**已全部失效**
///   （trackercdn 返回 status=2；anti.s 常返回试听片段），故不再保留；
/// - 受版权限制的顶级 VIP 歌曲（如周杰伦）**任何公开解析都拿不到完整音频**——
///   此时返回 nil，由调用方回退官方通道（可能仅试听）；导入自定义音源可解决。
enum BuiltinAudioSource {
    struct Resolved {
        let url: String
        let sourceName: String
    }

    static func resolve(item: MusicItem, quality: WellAudioQuality = .high) async -> Resolved? {
        await resolveViaGDStudio(item, quality: quality)
    }

    /// 音质设置 → GD 音乐 API 的 br 档位：
    /// 标准 128 / 较高 320 / 无损与 Hi-Res 用 999（GD 的无损档位）。
    private static func brValue(for quality: WellAudioQuality) -> String {
        switch quality {
        case .standard: return "128"
        case .high: return "320"
        case .lossless, .hiRes: return "999"
        }
    }

    // MARK: - GD 音乐 API

    private static func resolveViaGDStudio(_ item: MusicItem, quality: WellAudioQuality) async -> Resolved? {
        guard let (source, id) = platformSourceAndId(for: item), !id.isEmpty else { return nil }
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        let url = "https://music-api.gdstudio.xyz/api.php?types=url"
            + "&source=\(source)&id=\(encodedId)&br=\(brValue(for: quality))"

        // ⚠️ GD 服务瞬时 503 较常见（限流）：重试一次、间隔 0.6s，显著提升命中率。
        for attempt in 0..<2 {
            if let resolved = await fetchGDStudio(url) { return resolved }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        return nil
    }

    private static func fetchGDStudio(_ url: String) async -> Resolved? {
        guard let resp = try? await NetworkClient.shared.get(url, headers: [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15",
        ]),
        let json = NetworkClient.jsonObject(resp.data),
        let stream = json["url"] as? String, !stream.isEmpty,
        (json["br"] as? Int ?? 0) > 0 else { return nil }
        return Resolved(
            url: stream.replacingOccurrences(of: "http://", with: "https://"),
            sourceName: "内置音源")
    }

    /// 平台 → GD 音乐 API 的 source 名 + 歌曲 id。
    /// ⚠️ 与 RN 版内置音源（unblockSources.ts）对照：它只用 netease（Pyncmd）——
    /// GD 音乐 API 实测支持 netease / tencent；kugou / kuwo 的 source 会直接报
    /// 「not supported」，故只保留前两者。
    private static func platformSourceAndId(for item: MusicItem) -> (String, String)? {
        switch item.source {
        case .netease, .lx:
            guard let id = item.neteaseId else { return nil }
            return ("netease", id)
        case .qq:
            guard let mid = item.qqSongMid else { return nil }
            return ("tencent", mid)
        default:
            return nil
        }
    }
}
