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

    private func kugouEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}