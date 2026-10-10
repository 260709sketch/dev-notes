import Foundation

/// 酷狗音乐 API
final class KugouMusicAPI {
    static let shared = KugouMusicAPI()

    init() {}

    // MARK: 搜索（mobilecdn 接口）

    func search(keyword: String, limit: Int = 30) async throws -> [MusicItem] {
        let url = "https://mobilecdn.kugou.com/api/v3/search/song?" +
            "format=json&keyword=\(kugouEncode(keyword))&page=1&pagesize=\(limit)&showtype=1"
        let resp = try await NetworkClient.shared.get(url, headers: [
            "Referer": "https://m.kugou.com/",
        ])
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            return []
        }
        return info.compactMap { parseSong($0) }
    }

    private func parseSong(_ dict: [String: Any]) -> MusicItem? {
        guard let hash = dict["hash"] as? String,
              let name = dict["songname"] as? String else { return nil }
        let albumId = dict["album_id"] as? String
        return MusicItem(
            source: .kugou,
            title: name,
            artist: dict["singername"] as? String,
            album: dict["album_name"] as? String,
            albumCoverURL: albumCover(albumId: albumId),
            duration: TimeInterval(dict["duration"] as? Int ?? 0),
            kugouHash: hash
        )
    }

    /// 封面（album_id 拼图床）
    func albumCover(albumId: String?) -> String? {
        guard let albumId, !albumId.isEmpty else { return nil }
        return "https://img.kugou.com/stand/\(albumId)/300x300.jpg"
    }

    // MARK: 播放地址（play/getdata）

    func resolvePlayURL(item: MusicItem, highQuality: Bool) async throws -> String {
        guard let hash = item.kugouHash ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let url = "https://wwwapi.kugou.com/yy/index.php?" +
            "r=play/getdata&hash=\(hash)&album_id=&mid=\(UUID().uuidString.lowercased())&platid=4&_=\(ts)"
        let resp = try await NetworkClient.shared.get(url, headers: [
            "Referer": "https://www.kugou.com/",
        ])
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let playURL = data["play_url"] as? String, !playURL.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        return playURL
    }

    // MARK: 搜索歌手（mobilecdn search/singer）

    func searchArtists(keyword: String, limit: Int = 30) async throws -> [WellArtistSummary] {
        let url = "https://mobilecdn.kugou.com/api/v3/search/singer?" +
            "format=json&keyword=\(kugouEncode(keyword))&page=1&pagesize=\(limit)"
        let resp = try await NetworkClient.shared.get(url, headers: ["Referer": "https://www.kugou.com/"])
        guard let json = NetworkClient.jsonObject(resp.data) else { return [] }

        var list: [[String: Any]] = []
        if let arr = json["data"] as? [[String: Any]] {
            list = arr
        } else if let dict = json["data"] as? [String: Any],
                  let info = dict["info"] as? [[String: Any]] {
            list = info
        }

        var result: [WellArtistSummary] = []
        // 前若干个补全真实头像（与 kumone 一致，限制请求量）
        let fillCount = min(list.count, 8)
        for (index, item) in list.enumerated() {
            let singerId = (item["singerid"] as? Int).map(String.init)
                ?? (item["singerid"] as? String) ?? ""
            let name = (item["singername"] as? String) ?? ""
            guard !singerId.isEmpty, !name.isEmpty else { continue }
            var avatar: String? = (item["imgurl"] as? String)?.kugouNormalizedImage
            if index < fillCount, avatar == nil {
                avatar = await Self.kugouArtistAvatar(singerId: singerId)
            }
            result.append(WellArtistSummary(
                id: singerId, name: name, picURL: avatar,
                platform: .kugou, mid: singerId, subtitle: nil))
            if result.count >= limit { break }
        }
        return result
    }

    /// 歌手头像（singer/info）
    private static func kugouArtistAvatar(singerId: String) async -> String? {
        let id = singerId.replacingOccurrences(of: "kugou_", with: "")
        let url = "https://mobilecdn.kugou.com/api/v3/singer/info?singerid=\(id)"
        guard let resp = try? await NetworkClient.shared.get(url, headers: ["Referer": "https://www.kugou.com/"]),
              let json = NetworkClient.jsonObject(resp.data),
              let info = json["data"] as? [String: Any],
              let img = info["imgurl"] as? String, !img.isEmpty else { return nil }
        return img.kugouNormalizedImage
    }

    // MARK: 搜索专辑（mobilecdn search/album）

    func searchAlbums(keyword: String, limit: Int = 30) async throws -> [WellAlbumSummary] {
        let url = "https://mobilecdn.kugou.com/api/v3/search/album?" +
            "format=json&keyword=\(kugouEncode(keyword))&page=1&pagesize=\(limit)"
        let resp = try await NetworkClient.shared.get(url, headers: ["Referer": "https://www.kugou.com/"])
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
            let singer = (item["singername"] as? String) ?? "未知歌手"
            var pic = (item["imgurl"] as? String)?.kugouNormalizedImage
            if pic == nil { pic = "https://imge.kugou.com/stdmusic/400/album/\(albumId).jpg" }
            return WellAlbumSummary(
                id: albumId, name: name, picURL: pic, artistName: singer,
                platform: .kugou, albumMid: albumId)
        }
    }

    private func kugouEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

private extension String {
    /// 酷狗图床地址归一化：`{size}` 替换 + 协议补全
    var kugouNormalizedImage: String? {
        guard !isEmpty else { return nil }
        var s = replacingOccurrences(of: "{size}", with: "400")
        if s.hasPrefix("//") { s = "https:" + s }
        s = s.replacingOccurrences(of: "http://", with: "https://")
        return s
    }
}