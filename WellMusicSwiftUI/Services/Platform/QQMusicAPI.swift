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

    // MARK: 搜索歌手（musicu.fcg search_type=1）

    func searchArtists(keyword: String, limit: Int = 30) async throws -> [WellArtistSummary] {
        let body: [String: Any] = [
            "comm": ["ct": 19, "cv": 1859, "uin": "0", "format": "json"],
            "req_1": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "query": keyword,
                    "num_per_page": limit,
                    "page_num": 1,
                    "search_type": 1,
                    "grp": 1,
                ],
            ],
        ]
        let resp = try await NetworkClient.shared.postJSON(
            "https://u.y.qq.com/cgi-bin/musicu.fcg", body: body,
            headers: ["Referer": "https://y.qq.com/", "Origin": "https://y.qq.com"])
        guard let json = NetworkClient.jsonObject(resp.data),
              let req1 = json["req_1"] as? [String: Any],
              let data = req1["data"] as? [String: Any],
              let bodyDict = data["body"] as? [String: Any],
              let singer = bodyDict["singer"] as? [String: Any],
              let list = singer["list"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item in
            let mid = (item["singerMID"] as? String) ?? (item["mid"] as? String) ?? ""
            let name = (item["singerName"] as? String) ?? (item["name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let id = (item["singerID"] as? Int) ?? (item["id"] as? Int) ?? abs(mid.hashValue)
            var pic = (item["singerPic"] as? String) ?? (item["pic"] as? String) ?? ""
            pic = pic.replacingOccurrences(of: "http://", with: "https://")
            let songNum = (item["songNum"] as? Int) ?? 0
            return WellArtistSummary(
                id: "\(id)", name: name, picURL: pic.isEmpty ? nil : pic,
                platform: .qq, mid: mid.isEmpty ? nil : mid,
                subtitle: songNum > 0 ? "\(songNum) 首单曲" : nil)
        }
    }

    // MARK: 搜索专辑（musicu.fcg search_type=2）

    func searchAlbums(keyword: String, limit: Int = 30) async throws -> [WellAlbumSummary] {
        let body: [String: Any] = [
            "comm": ["ct": 19, "cv": 1859, "uin": "0", "format": "json"],
            "req_1": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "query": keyword,
                    "num_per_page": limit,
                    "page_num": 1,
                    "search_type": 2,
                    "grp": 1,
                ],
            ],
        ]
        let resp = try await NetworkClient.shared.postJSON(
            "https://u.y.qq.com/cgi-bin/musicu.fcg", body: body,
            headers: ["Referer": "https://y.qq.com/", "Origin": "https://y.qq.com"])
        guard let json = NetworkClient.jsonObject(resp.data),
              let req1 = json["req_1"] as? [String: Any],
              let data = req1["data"] as? [String: Any],
              let bodyDict = data["body"] as? [String: Any],
              let album = bodyDict["album"] as? [String: Any],
              let list = album["list"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item in
            let mid = (item["albumMID"] as? String) ?? (item["albummid"] as? String) ?? ""
            let name = (item["albumName"] as? String) ?? (item["albumname"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let id = (item["albumID"] as? Int) ?? (item["albumid"] as? Int) ?? abs(mid.hashValue)
            var pic = (item["albumPic"] as? String) ?? (item["pic"] as? String) ?? ""
            pic = pic.replacingOccurrences(of: "http://", with: "https://")
            if pic.isEmpty, !mid.isEmpty {
                pic = "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(mid).jpg"
            }
            var singerName = (item["singerName"] as? String) ?? ""
            if singerName.isEmpty, let singers = item["singer"] as? [[String: Any]] {
                singerName = singers.compactMap { $0["name"] as? String }.joined(separator: "/")
            }
            return WellAlbumSummary(
                id: "\(id)", name: name, picURL: pic.isEmpty ? nil : pic,
                artistName: singerName.isEmpty ? "未知歌手" : singerName,
                platform: .qq, albumMid: mid.isEmpty ? nil : mid)
        }
    }

    private func qqEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}