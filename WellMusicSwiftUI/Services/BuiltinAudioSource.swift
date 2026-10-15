import Foundation

/// 内置音源（歌曲解锁）：把任意平台的歌曲，自动匹配**酷狗 / 酷我**的完整音频源播放。
///
/// 与「官方平台通道」的区别：官方通道对 VIP/试听受限歌曲只给 30 秒片段；
/// 本模块走第三方平台的公开播放通道（搜索匹配同名歌曲 → 取完整直链），
/// 是「内置音源」开关开启时的主力。
///
/// 通道：
/// - 酷狗：`mobilecdn` 搜索匹配 → `MD5(hash + "kgcloudv2")` key →
///   `trackercdn.kugou.com/i/v2/` 直链（返回 `url` 数组）
/// - 酷我：`search.kuwo.cn` 搜索匹配 → `antiserver.kuwo.cn/anti.s`
///   convert_url（返回文本中的 http 直链）
enum BuiltinAudioSource {
    struct Resolved {
        let url: String
        let sourceName: String
    }

    /// 依次尝试酷狗 / 酷我完整源；都不行返回 nil（由调用方回退官方通道）。
    static func resolve(item: MusicItem) async -> Resolved? {
        if let resolved = await resolveViaKugou(item) { return resolved }
        if let resolved = await resolveViaKuwo(item) { return resolved }
        return nil
    }

    // MARK: - 酷狗

    private static func resolveViaKugou(_ item: MusicItem) async -> Resolved? {
        guard let list = try? await KugouMusicAPI.shared.search(keyword: searchKeyword(item), limit: 10),
              !list.isEmpty else { return nil }
        for candidate in list.prefix(5) {
            guard let hash = candidate.kugouHash, !hash.isEmpty,
                  matches(item: item,
                          title: candidate.title,
                          artist: candidate.artist,
                          durationSeconds: candidate.duration) else { continue }
            let albumID = candidate.platformAlbumId ?? ""
            let key = Data("\(hash)kgcloudv2".utf8).md5Hex()
            let url = "https://trackercdn.kugou.com/i/v2/?key=\(key)&hash=\(hash)"
                + "&appid=1005&pid=2&cmd=25&behavior=play&album_id=\(albumID)"
            guard let resp = try? await NetworkClient.shared.get(url, headers: [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15",
            ]),
            let json = NetworkClient.jsonObject(resp.data),
            let urls = json["url"] as? [String],
            let first = urls.first, !first.isEmpty else { continue }
            return Resolved(url: first, sourceName: "内置音源·酷狗")
        }
        return nil
    }

    // MARK: - 酷我

    private static func resolveViaKuwo(_ item: MusicItem) async -> Resolved? {
        let query = searchKeyword(item)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let searchURL = "https://search.kuwo.cn/r.s?&correct=1&vipver=1&stype=comprehensive"
            + "&encoding=utf8&rformat=json&mobi=1&show_copyright_off=1&searchapi=6&all=\(query)"
        guard let resp = try? await NetworkClient.shared.get(searchURL, headers: [
            "User-Agent": "okhttp/3.10.0",
        ]),
        let json = NetworkClient.jsonObject(resp.data),
        let content = json["content"] as? [[String: Any]], content.count >= 2,
        let musicPage = content[1]["musicpage"] as? [String: Any],
        let songs = musicPage["abslist"] as? [[String: Any]] else { return nil }

        for song in songs.prefix(5) {
            guard let musicRID = song["MUSICRID"] as? String,
                  let rid = musicRID.components(separatedBy: "_").last,
                  let title = song["SONGNAME"] as? String,
                  let artist = song["ARTIST"] as? String else { continue }
            let durationSeconds = Double((song["DURATION"] as? String) ?? "")
                ?? Double(song["DURATION"] as? Int ?? 0)
            guard matches(item: item, title: title, artist: artist, durationSeconds: durationSeconds) else { continue }

            let convertURL = "https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3&response=url&rid=MUSIC_\(rid)"
            guard let streamResp = try? await NetworkClient.shared.get(convertURL, headers: [
                "User-Agent": "okhttp/3.10.0",
            ]),
            let text = streamResp.string,
            let range = text.range(of: #"http[^\s$"]+"#, options: .regularExpression) else { continue }
            let url = String(text[range])
            if !url.isEmpty {
                return Resolved(url: url, sourceName: "内置音源·酷我")
            }
        }
        return nil
    }

    // MARK: - 匹配（标题命中 + 歌手交集 + 时长接近）

    private static func searchKeyword(_ item: MusicItem) -> String {
        [item.title, item.artist ?? ""]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func matches(item: MusicItem,
                                title: String,
                                artist: String?,
                                durationSeconds: Double) -> Bool {
        let expectedTitle = normalize(item.title)
        let candidateTitle = normalize(title)
        guard !expectedTitle.isEmpty, !candidateTitle.isEmpty else { return false }
        let titleHit = expectedTitle == candidateTitle
            || expectedTitle.contains(candidateTitle)
            || candidateTitle.contains(expectedTitle)
        guard titleHit else { return false }

        // 歌手交集（避免同名异歌手）
        let expectedArtists = artistTokens(item.artist)
        let candidateArtists = artistTokens(artist)
        if !expectedArtists.isEmpty, !candidateArtists.isEmpty {
            let hit = !expectedArtists.isDisjoint(with: candidateArtists)
            if !hit { return false }
        }

        // 时长接近（±8 秒；任一侧缺失时长时跳过该检查）
        if item.duration > 1, durationSeconds > 1 {
            if abs(durationSeconds - item.duration) > 8 { return false }
        }
        return true
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "【", with: "(")
            .replacingOccurrences(of: "】", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func artistTokens(_ raw: String?) -> Set<String> {
        guard let raw, !raw.isEmpty else { return [] }
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: "/、,&|"))
        return Set(parts.map { normalize($0) }.filter { !$0.isEmpty })
    }
}
