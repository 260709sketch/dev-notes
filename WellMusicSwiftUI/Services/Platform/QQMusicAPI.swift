import Foundation

/// QQ 音乐 API
final class QQMusicAPI {
    static let shared = QQMusicAPI()

    init() {}

    // MARK: 搜索

    func search(keyword: String, limit: Int = 30) async throws -> [MusicItem] {
        let url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?" +
            "w=\(qqEncode(keyword))&format=json&p=1&n=\(limit)&cr=1&t=0&aggr=1&new_json=1" +
            "&remoteplace=txt.yqq.center"
        let resp = try await NetworkClient.shared.get(url, headers: [
            "Referer": "https://y.qq.com/",
            "Origin": "https://y.qq.com",
        ])
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let song = data["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { parseSong($0) }
    }

    private func parseSong(_ dict: [String: Any]) -> MusicItem? {
        guard let songMid = dict["songmid"] as? String,
              let name = dict["songname"] as? String else { return nil }
        let singers = (dict["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return MusicItem(
            source: .qq,
            title: name,
            artist: singers.joined(separator: "/"),
            album: dict["albumname"] as? String,
            albumCoverURL: albumCover(songMid),
            duration: TimeInterval(dict["interval"] as? Int ?? 0),
            qqSongMid: songMid
        )
    }

    /// 专辑封面（由 songmid 拼图床）
    func albumCover(_ songMid: String) -> String {
        "https://y.qq.com/music/photo_new/T002R300x300M000\(songMid).jpg"
    }

    // MARK: 播放地址（mobile express vkey）

    func resolvePlayURL(item: MusicItem, highQuality: Bool) async throws -> String {
        guard let mid = item.qqSongMid ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        let guid = String(Int.random(in: 1_000_000_000...9_999_999_999))
        let filename = "C400\(mid).m4a"
        let url = "https://c.y.qq.com/base/fcgi-bin/fcg_music_express_mobile3.fcg?" +
            "format=json&platform=yqq&cid=205361747&uin=0&songmid=\(mid)&filename=\(filename)&guid=\(guid)"
        let resp = try await NetworkClient.shared.get(url, headers: ["Referer": "https://y.qq.com/"])
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let items = data["items"] as? [[String: Any]],
              let first = items.first,
              let vkey = first["vkey"] as? String, !vkey.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        return "https://dl.stream.qqmusic.qq.com/\(filename)?vkey=\(vkey)&guid=\(guid)&uin=0&fromtag=38"
    }

    private func qqEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}