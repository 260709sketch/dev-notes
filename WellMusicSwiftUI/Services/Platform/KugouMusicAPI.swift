import Foundation

/// 酷狗音乐 API
///
/// 对齐 RN 版 v90 `helpers/userApi/kugou-music-api.js`：
/// - 搜索结果字段做了多键名兼容（不同接口返回 album_name / albumname / AlbumName 等）
/// - 封面按 `imgUrl → album_pic → cover → trans_param.union_cover → 按 albumId 拼图床` 逐级回退
/// - 歌手搜索结果会批量补全真实头像（前 10 个）
final class KugouMusicAPI {
    static let shared = KugouMusicAPI()

    init() {}

    private let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Referer": "https://www.kugou.com/",
    ]

    // MARK: - 搜索歌曲

    func search(keyword: String, limit: Int = 30) async throws -> [MusicItem] {
        let url = "https://mobilecdn.kugou.com/api/v3/search/song?" +
            "format=json&keyword=\(kugouEncode(keyword))&page=1&pagesize=\(limit)" +
            "&showtype=1&plat=2&version=8990"
        let resp = try await NetworkClient.shared.get(url, headers: headers)
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            return []
        }
        return info.compactMap { parseSong($0) }
    }

    /// 统一歌曲格式化（多键名兼容 + 封面回退链）。
    /// - Parameter fallbackSinger: 专辑/歌手详情页可传入歌手名兜底。
    private func parseSong(_ dict: [String: Any], fallbackSinger: String? = nil) -> MusicItem? {
        let hash = (dict["hash"] as? String) ?? (dict["FileHash"] as? String)
            ?? (dict["file_hash"] as? String) ?? ""
        guard !hash.isEmpty else { return nil }

        let title = (dict["songname"] as? String) ?? (dict["SongName"] as? String)
            ?? (dict["name"] as? String) ?? (dict["title"] as? String)
            ?? Self.titleFromFilename(dict["filename"] as? String)
        let albumName = (dict["album_name"] as? String) ?? (dict["albumname"] as? String)
            ?? (dict["AlbumName"] as? String) ?? (dict["album"] as? String) ?? "未知专辑"
        var artist = (dict["artist_name"] as? String) ?? (dict["singername"] as? String)
            ?? (dict["SingerName"] as? String) ?? (dict["author"] as? String) ?? ""
        if artist.isEmpty, let fallbackSinger, !fallbackSinger.isEmpty, fallbackSinger != "未知歌手" {
            artist = fallbackSinger
        }
        let albumId = (dict["album_id"] as? String) ?? (dict["albumid"] as? String)
            ?? (dict["AlbumID"] as? String) ?? (dict["album_id"] as? Int).map(String.init) ?? ""
        let duration = TimeInterval((dict["duration"] as? Int) ?? (dict["timelength"] as? Int)
            ?? (dict["Duration"] as? Int) ?? 0)

        return MusicItem(
            source: .kugou,
            title: title,
            artist: artist.isEmpty ? nil : artist,
            album: albumName,
            albumCoverURL: Self.coverURL(from: dict, albumId: albumId),
            duration: duration,
            kugouHash: hash
        )
    }

    /// 封面回退链：imgUrl → album_pic → cover → imgurl → trans_param.union_cover → 按 albumId 拼图床。
    private static func coverURL(from dict: [String: Any], albumId: String) -> String? {
        for key in ["imgUrl", "album_pic", "cover", "imgurl", "singer_pic"] {
            if let raw = dict[key] as? String, !raw.isEmpty, let normalized = raw.kugouNormalizedImage {
                return normalized
            }
        }
        if let trans = dict["trans_param"] as? [String: Any],
           let union = trans["union_cover"] as? String, !union.isEmpty {
            return union.replacingOccurrences(of: "{size}", with: "400")
        }
        guard !albumId.isEmpty else { return nil }
        return "https://imge.kugou.com/stdmusic/400/album/\(albumId).jpg"
    }

    /// 从 `歌手 - 歌名.mp3` 形式的 filename 里提取歌名。
    private static func titleFromFilename(_ filename: String?) -> String {
        guard let filename, !filename.isEmpty else { return "未知歌曲" }
        let parts = filename.components(separatedBy: " - ")
        if parts.count >= 2 {
            return parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        }
        return filename
    }

    // MARK: - 封面

    /// 专辑封面。此前误用 `img.kugou.com/stand/...`，正确图床是 `imge.kugou.com/stdmusic/400/album/...`。
    func albumCover(albumId: String?) -> String? {
        guard let albumId, !albumId.isEmpty else { return nil }
        return "https://imge.kugou.com/stdmusic/400/album/\(albumId).jpg"
    }

    // MARK: - 播放地址（play/getdata）

    func resolvePlayURL(item: MusicItem, highQuality: Bool) async throws -> String {
        guard let hash = item.kugouHash ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let url = "https://wwwapi.kugou.com/yy/index.php?" +
            "r=play/getdata&hash=\(hash)&album_id=&mid=\(UUID().uuidString.lowercased())&platid=4&_=\(ts)"
        let resp = try await NetworkClient.shared.get(url, headers: headers)
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let playURL = data["play_url"] as? String, !playURL.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        return playURL
    }

    // MARK: - 搜索歌手

    func searchArtists(keyword: String, limit: Int = 30) async throws -> [WellArtistSummary] {
        var result = await fetchSingerList(keyword: keyword, limit: limit)
        // 主接口为空时，退回「歌曲搜索 → 提取去重歌手」
        if result.isEmpty {
            result = await artistsFromSongSearch(keyword: keyword)
        }
        let trimmed = Array(result.prefix(limit))
        return await fillArtistAvatars(trimmed)
    }

    private func fetchSingerList(keyword: String, limit: Int) async -> [WellArtistSummary] {
        let url = "https://mobilecdn.kugou.com/api/v3/search/singer?" +
            "format=json&keyword=\(kugouEncode(keyword))&page=1&pagesize=\(limit)"
        guard let resp = try? await NetworkClient.shared.get(url, headers: headers),
              let json = NetworkClient.jsonObject(resp.data) else { return [] }

        var list: [[String: Any]] = []
        if let arr = json["data"] as? [[String: Any]] {
            list = arr
        } else if let dict = json["data"] as? [String: Any],
                  let info = dict["info"] as? [[String: Any]] {
            list = info
        }
        return list.compactMap { parseArtist($0) }
    }

    /// 从歌曲搜索结果中提取去重歌手（酷狗歌手接口不稳定时的兜底）。
    private func artistsFromSongSearch(keyword: String) async -> [WellArtistSummary] {
        let url = "https://songsearch.kugou.com/song_search_v2?" +
            "keyword=\(kugouEncode(keyword))&page=1&pagesize=30&userid=0" +
            "&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1"
        guard let resp = try? await NetworkClient.shared.get(url, headers: headers),
              let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let lists = data["lists"] as? [[String: Any]] else { return [] }

        var seen = Set<String>()
        var out: [WellArtistSummary] = []
        for song in lists {
            guard let singers = song["Singers"] as? [[String: Any]] else { continue }
            for singer in singers {
                let id = (singer["id"] as? Int).map(String.init) ?? (singer["id"] as? String) ?? ""
                let name = (singer["name"] as? String) ?? ""
                guard !id.isEmpty, !name.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                var pic = (singer["pic"] as? String)?.kugouNormalizedImage
                if pic == nil {
                    pic = "https://singerimg.kugou.com/uploadpic/softhead/400/\(id).jpg"
                }
                out.append(WellArtistSummary(
                    id: id, name: name, picURL: pic,
                    platform: .kugou, mid: id, subtitle: nil))
            }
        }
        return out
    }

    private func parseArtist(_ dict: [String: Any]) -> WellArtistSummary? {
        let id = (dict["singerid"] as? Int).map(String.init)
            ?? (dict["singer_id"] as? Int).map(String.init)
            ?? (dict["singerid"] as? String) ?? (dict["artist_id"] as? String) ?? ""
        let name = (dict["singername"] as? String) ?? (dict["artist_name"] as? String)
            ?? (dict["name"] as? String) ?? (dict["SingerName"] as? String) ?? ""
        guard !id.isEmpty, !name.isEmpty else { return nil }
        var pic = (dict["imgurl"] as? String)?.kugouNormalizedImage
            ?? (dict["singer_pic"] as? String)?.kugouNormalizedImage
            ?? (dict["avatar"] as? String)?.kugouNormalizedImage
        if pic == nil {
            pic = "https://singerimg.kugou.com/uploadpic/softhead/400/\(id).jpg"
        }
        let works = (dict["songcount"] as? Int) ?? (dict["song_num"] as? Int) ?? 0
        return WellArtistSummary(
            id: id, name: name, picURL: pic,
            platform: .kugou, mid: id,
            subtitle: works > 0 ? "\(works) 首单曲" : nil)
    }

    /// 并发补全前 10 个歌手的真实头像（默认图床多为占位图）。
    private func fillArtistAvatars(_ list: [WellArtistSummary]) async -> [WellArtistSummary] {
        var out = list
        let needCount = min(out.count, 10)
        await withTaskGroup(of: (Int, String?).self) { group in
            for i in 0..<needCount {
                let id = out[i].id.replacingOccurrences(of: "kugou_", with: "")
                group.addTask { (i, await Self.artistAvatar(singerId: id, headers: self.headers)) }
            }
            for await (index, avatar) in group {
                if let avatar, !avatar.isEmpty, index < out.count {
                    out[index].picURL = avatar
                }
            }
        }
        return out
    }

    private static func artistAvatar(singerId: String, headers: [String: String]) async -> String? {
        let url = "https://mobilecdn.kugou.com/api/v3/singer/info?singerid=\(singerId)"
        guard let resp = try? await NetworkClient.shared.get(url, headers: headers),
              let json = NetworkClient.jsonObject(resp.data),
              let info = json["data"] as? [String: Any],
              let img = info["imgurl"] as? String, !img.isEmpty else { return nil }
        return img.kugouNormalizedImage
    }

    // MARK: - 搜索专辑

    func searchAlbums(keyword: String, limit: Int = 30) async throws -> [WellAlbumSummary] {
        let url = "https://mobilecdn.kugou.com/api/v3/search/album?" +
            "format=json&keyword=\(kugouEncode(keyword))&page=1&pagesize=\(limit)"
        let resp = try await NetworkClient.shared.get(url, headers: headers)
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let list = data["info"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item in
            let albumId = (item["albumid"] as? String) ?? (item["album_id"] as? String)
                ?? (item["albumid"] as? Int).map(String.init) ?? ""
            let name = (item["albumname"] as? String) ?? (item["album_name"] as? String) ?? ""
            guard !name.isEmpty, !albumId.isEmpty else { return nil }
            let singer = (item["singername"] as? String)
                ?? (item["artist_name"] as? String) ?? "未知歌手"
            var pic = (item["imgurl"] as? String)?.kugouNormalizedImage
                ?? (item["album_pic"] as? String)?.kugouNormalizedImage
            if pic == nil { pic = "https://imge.kugou.com/stdmusic/400/album/\(albumId).jpg" }
            return WellAlbumSummary(
                id: albumId, name: name, picURL: pic, artistName: singer,
                platform: .kugou, albumMid: albumId)
        }
    }

    // MARK: - 歌手详情（头像 + 热门歌曲）

    /// 获取歌手详情。返回 `(singerName, avatar, songs)`。
    func singerDetail(singerId: String) async throws -> (name: String, avatar: String?, songs: [MusicItem]) {
        let id = singerId.replacingOccurrences(of: "kugou_", with: "")

        // 1) 基本信息
        var singerName = ""
        var avatar: String?
        let infoURL = "https://mobilecdn.kugou.com/api/v3/singer/info?singerid=\(id)"
        if let resp = try? await NetworkClient.shared.get(infoURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let info = json["data"] as? [String: Any] {
            singerName = (info["singername"] as? String) ?? ""
            avatar = (info["imgurl"] as? String)?.kugouNormalizedImage
        }
        if avatar == nil {
            avatar = "https://singerimg.kugou.com/uploadpic/softhead/400/\(id).jpg"
        }

        // 2) 热门歌曲
        let songURL = "https://mobilecdn.kugou.com/api/v3/singer/song?singerid=\(id)&page=1&pagesize=50"
        var songs: [MusicItem] = []
        if let resp = try? await NetworkClient.shared.get(songURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let data = json["data"] as? [String: Any],
           let info = data["info"] as? [[String: Any]] {
            songs = info.compactMap { parseSong($0, fallbackSinger: singerName) }
        }
        return (singerName, avatar, songs)
    }

    /// 歌手歌曲分页（展开全部懒加载用）。
    func singerSongs(singerId: String, page: Int = 1, limit: Int = 30) async throws -> (list: [MusicItem], total: Int) {
        let id = singerId.replacingOccurrences(of: "kugou_", with: "")
        let url = "https://mobilecdn.kugou.com/api/v3/singer/song?singerid=\(id)&page=\(page)&pagesize=\(limit)"
        guard let resp = try? await NetworkClient.shared.get(url, headers: headers),
              let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            return ([], 0)
        }
        let singerName = (info.first?["singername"] as? String) ?? ""
        let list = info.compactMap { parseSong($0, fallbackSinger: singerName) }
        return (list, (data["total"] as? Int) ?? 0)
    }

    // MARK: - 专辑详情（歌曲列表）

    /// 获取专辑歌曲列表。返回 `(albumName, cover, songs)`。
    func albumDetail(albumId: String) async throws -> (name: String, cover: String?, songs: [MusicItem]) {
        let id = albumId.replacingOccurrences(of: "kugou_album_", with: "")
            .replacingOccurrences(of: "kugou_", with: "")

        var albumName = "未知专辑"
        var cover: String?
        let infoURL = "https://mobilecdn.kugou.com/api/v3/album/info?albumid=\(id)"
        if let resp = try? await NetworkClient.shared.get(infoURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let info = json["data"] as? [String: Any] {
            albumName = (info["albumname"] as? String) ?? (info["album_name"] as? String) ?? albumName
            cover = (info["imgurl"] as? String)?.kugouNormalizedImage
        }
        if cover == nil { cover = "https://imge.kugou.com/stdmusic/400/album/\(id).jpg" }

        var albumArtist = "未知歌手"
        if let resp = try? await NetworkClient.shared.get(infoURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let info = json["data"] as? [String: Any] {
            albumArtist = (info["singername"] as? String) ?? albumArtist
        }

        let songURL = "https://mobilecdn.kugou.com/api/v3/album/song?albumid=\(id)&page=1&pagesize=100"
        var songs: [MusicItem] = []
        if let resp = try? await NetworkClient.shared.get(songURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let data = json["data"] as? [String: Any],
           let info = data["info"] as? [[String: Any]] {
            songs = info.compactMap { parseSong($0, fallbackSinger: albumArtist) }
        }
        return (albumName, cover, songs)
    }

    private func kugouEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

private extension String {
    /// 酷狗图床地址归一化：`{size}` 替换 + 协议补全。
    var kugouNormalizedImage: String? {
        guard !isEmpty else { return nil }
        var s = replacingOccurrences(of: "{size}", with: "400")
        if s.hasPrefix("//") { s = "https:" + s }
        s = s.replacingOccurrences(of: "http://", with: "https://")
        return s
    }
}
