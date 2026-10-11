import Foundation

/// 酷我音乐 API（需先取 cookie 中的 kw_token 作为 csrf 头）
final class KuwoMusicAPI {
    static let shared = KuwoMusicAPI()

    init() {}

    /// 首页抓取的 csrf token（kw_token cookie）
    private var csrfToken: String = ""
    private var tokenLoaded = false

    // MARK: csrf token

    /// 从首页 Set-Cookie 拿 kw_token
    private func loadTokenIfNeeded() async {
        if tokenLoaded { return }
        guard let u = URL(string: "https://www.kuwo.cn/") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse,
           let setCookie = http.allHeaderFields["Set-Cookie"] as? String {
            // kw_token=xxxx;  ...
            let parts = setCookie.components(separatedBy: ";")
            for p in parts {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces) == "kw_token" {
                    csrfToken = kv[1].trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        tokenLoaded = true
    }

    func kuwoHeaders() async -> [String: String] {
        await loadTokenIfNeeded()
        var headers = [
            "Referer": "https://www.kuwo.cn/",
            "Origin": "https://www.kuwo.cn",
        ]
        if !csrfToken.isEmpty {
            headers["csrf"] = csrfToken
            headers["Cookie"] = "kw_token=\(csrfToken)"
        }
        return headers
    }

    // MARK: 搜索

    func search(keyword: String, limit: Int = 30) async throws -> [MusicItem] {
        let url = "https://www.kuwo.cn/api/www/search/searchMusicBykeyWord?" +
            "key=\(kuwoEncode(keyword))&pn=1&rn=\(limit)&httpsStatus=1"
        let resp = try await NetworkClient.shared.get(url, headers: await kuwoHeaders())
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let list = data["list"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { parseSong($0) }
    }

    private func parseSong(_ dict: [String: Any]) -> MusicItem? {
        guard let rid = dict["rid"] as? Int, rid > 0,
              let name = dict["name"] as? String else { return nil }
        // 封面 pic 可能是相对路径
        var cover = dict["pic"] as? String
        if let c = cover, c.hasPrefix("//") { cover = "https:" + c }
        let durationMs = dict["duration"] as? Int ?? 0
        return MusicItem(
            source: .kuwo,
            title: name,
            artist: dict["artist"] as? String,
            album: dict["album"] as? String,
            albumCoverURL: cover,
            duration: Double(durationMs) / 1000.0,
            kuwoRid: String(rid)
        )
    }

    // MARK: 播放地址（playUrl 接口）

    func resolvePlayURL(item: MusicItem, quality: WellAudioQuality) async throws -> String {
        guard let rid = item.kuwoRid ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        let url = "https://www.kuwo.cn/api/v1/www/music/playUrl?" +
            "mid=\(rid)&type=music&httpsStatus=1&br=\(quality.kuwoBr)"
        let resp = try await NetworkClient.shared.get(url, headers: await kuwoHeaders())
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let playURL = data["url"] as? String, !playURL.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        return playURL
    }

    private func kuwoEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}