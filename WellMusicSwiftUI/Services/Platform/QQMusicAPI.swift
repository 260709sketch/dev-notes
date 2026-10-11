import Foundation

/// QQ 音乐 API
///
/// 搜索统一走移动端 `SearchCgiService`（musics.fcg + zzcSign），
/// 与 RN 版 v90 `helpers/userApi/qq-music-api.js` 对齐 —— 相比旧的 web
/// `client_search_cp` 接口，移动端接口结果更全、字段更规范。
final class QQMusicAPI {
    static let shared = QQMusicAPI()

    init() {}

    private static let musicuAPI = "https://u.y.qq.com/cgi-bin/musicu.fcg"
    private static let mobileUA = "QQMusic 14090508(android 12)"

    // MARK: - 公共 comm 参数（与 RN 版 getComm() 一致）

    private func mobileComm() -> [String: Any] {
        [
            "ct": "11", "cv": "14090508", "v": "14090508", "tmeAppID": "qqmusic",
            "phonetype": "EBG-AN10", "deviceScore": "553.47", "devicelevel": "50",
            "newdevicelevel": "20", "rom": "HuaWei/EMOTION/EmotionUI_14.2.0", "os_ver": "12",
            "OpenUDID": "0", "OpenUDID2": "0", "QIMEI36": "0", "udid": "0", "chid": "0",
            "aid": "0", "oaid": "0", "taid": "0", "tid": "0", "wid": "0", "uid": "0",
            "sid": "0", "modeSwitch": "6", "teenMode": "0", "ui_mode": "2", "nettype": "1020",
            "v4ip": "",
        ]
    }

    /// 移动端签名请求：POST musics.fcg?sign=zzc...
    /// 签名基于**实际发送的 JSON 字节**，所以先用固定的 .sortedKeys 序列化再签名。
    private func signedRequest(_ payload: [String: Any]) async throws -> [String: Any]? {
        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let bodyString = String(data: bodyData, encoding: .utf8) else { return nil }
        let sign = QQMusicSign.sign(bodyString)

        guard let url = URL(string: "\(Self.musicuAPI)?sign=\(sign)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = bodyData

        let resp = try await NetworkClient.shared.rawRequest(req)
        return NetworkClient.jsonObject(resp.data)
    }

    /// 取搜索结果体：兼容 `req.data.body` 与 `req.data` 两种外层结构。
    private func searchItems(_ keyword: String, searchType: Int, limit: Int, page: Int, key: String) async throws -> [[String: Any]] {
        let payload: [String: Any] = [
            "comm": mobileComm(),
            "req": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicMobile",
                "param": [
                    "search_type": searchType,
                    "searchid": String(Int.random(in: 100_000_000_000_000...999_999_999_999_999)),
                    "query": keyword,
                    "page_num": page,
                    "num_per_page": limit,
                    "highlight": 0,
                    "nqc_flag": 0,
                    "multi_zhida": 0,
                    "cat": 2,
                    "grp": 1,
                    "sin": 0,
                    "sem": 0,
                ],
            ],
        ]
        guard let json = try await signedRequest(payload),
              let req = json["req"] as? [String: Any],
              let data = req["data"] as? [String: Any] else {
            return []
        }
        let resultData = (data["body"] as? [String: Any]) ?? data
        if let list = resultData[key] as? [[String: Any]] { return list }
        // 歌手结果在新旧结构里键名不同
        if let list = resultData["singer"] as? [[String: Any]] { return list }
        return []
    }

    // MARK: - 搜索歌曲（search_type = 0）

    func search(keyword: String, limit: Int = 30) async throws -> [MusicItem] {
        try await searchItems(keyword, searchType: 0, limit: limit, page: 1, key: "item_song")
            .compactMap { parseMobileSong($0) }
    }

    // MARK: - 字段解析（移动端 item_song 结构）

    private func parseMobileSong(_ dict: [String: Any]) -> MusicItem? {
        let mid = (dict["mid"] as? String) ?? (dict["songmid"] as? String) ?? ""
        guard !mid.isEmpty else { return nil }
        let title = (dict["title"] as? String) ?? (dict["name"] as? String) ?? "未知歌曲"
        let singers = (dict["singer"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        let albumDict = dict["album"] as? [String: Any]
        let albumName = albumDict?["name"] as? String
        let albumMid = (albumDict?["mid"] as? String) ?? ""
        let fileDict = dict["file"] as? [String: Any]
        let mediaMid = (fileDict?["media_mid"] as? String) ?? ""
        let interval = TimeInterval((dict["interval"] as? Int) ?? 0)

        var item = MusicItem(
            source: .qq,
            title: title,
            artist: singers.isEmpty ? nil : singers.joined(separator: "/"),
            album: albumName,
            albumCoverURL: albumMid.isEmpty ? nil : Self.albumCoverImage(albumMid),
            duration: interval,
            qqSongMid: mid
        )
        if !mediaMid.isEmpty { item.qqMediaMid = mediaMid }
        return item
    }

    private func parseMobileArtist(_ dict: [String: Any]) -> WellArtistSummary? {
        let mid = (dict["mid"] as? String) ?? (dict["singerMID"] as? String) ?? ""
        let name = (dict["name"] as? String) ?? (dict["singername"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let id = (dict["id"] as? Int) ?? abs(mid.hashValue)
        var pic = (dict["pic"] as? String) ?? (dict["singerPic"] as? String) ?? ""
        pic = pic.replacingOccurrences(of: "http://", with: "https://")
        let songNum = (dict["songNum"] as? Int) ?? (dict["songnum"] as? Int) ?? 0
        return WellArtistSummary(
            id: "\(id)", name: name, picURL: pic.isEmpty ? nil : pic,
            platform: .qq, mid: mid.isEmpty ? nil : mid,
            subtitle: songNum > 0 ? "\(songNum) 首单曲" : nil)
    }

    private func parseMobileAlbum(_ dict: [String: Any]) -> WellAlbumSummary? {
        let mid = (dict["mid"] as? String) ?? (dict["albummid"] as? String) ?? ""
        let name = (dict["name"] as? String) ?? (dict["albumname"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let id = (dict["id"] as? Int) ?? abs(mid.hashValue)
        var pic = (dict["pic"] as? String) ?? (dict["albumPic"] as? String) ?? ""
        pic = pic.replacingOccurrences(of: "http://", with: "https://")
        if pic.isEmpty, !mid.isEmpty { pic = Self.albumCoverImage(mid) }
        var singerName = ""
        if let singers = dict["singer"] as? [[String: Any]] {
            singerName = singers.compactMap { $0["name"] as? String }.joined(separator: "/")
        }
        if singerName.isEmpty { singerName = (dict["singername"] as? String) ?? "" }
        return WellAlbumSummary(
            id: "\(id)", name: name, picURL: pic.isEmpty ? nil : pic,
            artistName: singerName.isEmpty ? "未知歌手" : singerName,
            platform: .qq, albumMid: mid.isEmpty ? nil : mid)
    }

    // MARK: - 封面

    /// QQ 专辑封面。正确的图床域名是 `y.gtimg.cn`（此前误用 `y.qq.com` 会 404）。
    static func albumCoverImage(_ albumMid: String, size: Int = 300) -> String {
        "https://y.gtimg.cn/music/photo_new/T002R\(size)x\(size)M000\(albumMid).jpg"
    }

    func albumCover(_ songMid: String) -> String {
        Self.albumCoverImage(songMid)
    }

    // MARK: - 播放地址（mobile express vkey）

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

    // MARK: - 搜索歌手 / 专辑（对外接口）

    func searchArtists(keyword: String, limit: Int = 30) async throws -> [WellArtistSummary] {
        try await searchItems(keyword, searchType: 1, limit: limit, page: 1, key: "item_singer")
            .compactMap { parseMobileArtist($0) }
    }

    func searchAlbums(keyword: String, limit: Int = 30) async throws -> [WellAlbumSummary] {
        try await searchItems(keyword, searchType: 2, limit: limit, page: 1, key: "item_album")
            .compactMap { parseMobileAlbum($0) }
    }

    // MARK: - 歌手歌曲（展开全部 / 详情页用）

    func singerSongs(singerMid: String, begin: Int = 0, num: Int = 30) async throws -> (list: [MusicItem], total: Int, hasMore: Bool) {
        let payload: [String: Any] = [
            "comm": mobileComm(),
            "req": [
                "module": "musichall.song_list_server",
                "method": "GetSingerSongList",
                "param": ["singerMid": singerMid, "begin": begin, "num": num, "order": 1],
            ],
        ]
        guard let json = try await signedRequest(payload),
              let req = json["req"] as? [String: Any],
              let data = req["data"] as? [String: Any] else {
            return ([], 0, false)
        }
        let songList = data["songList"] as? [[String: Any]] ?? []
        let total = (data["totalNum"] as? Int) ?? 0
        let list = songList.compactMap { entry -> MusicItem? in
            let song = (entry["songInfo"] as? [String: Any]) ?? entry
            return parseMobileSong(song)
        }
        return (list, total, begin + list.count < total)
    }

    // MARK: - 专辑歌曲（专辑详情展开）

    func albumSongs(albumMid: String) async throws -> [MusicItem] {
        let url = "https://i.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg?" +
            "platform=h5page&albummid=\(albumMid)&g_tk=938407465&uin=0&format=json" +
            "&inCharset=utf-8&outCharset=utf-8&notice=0&platform=h5&needNewCode=1"
        let resp = try await NetworkClient.shared.get(url, headers: ["Referer": "https://y.qq.com/"])
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let list = data["list"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { dict -> MusicItem? in
            guard let mid = dict["songmid"] as? String else { return nil }
            let title = (dict["songname"] as? String) ?? (dict["name"] as? String) ?? "未知歌曲"
            let singers = (dict["singer"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String } ?? []
            let albumMid = (dict["albummid"] as? String) ?? ""
            var item = MusicItem(
                source: .qq,
                title: title,
                artist: singers.isEmpty ? nil : singers.joined(separator: "/"),
                album: dict["albumname"] as? String,
                albumCoverURL: albumMid.isEmpty ? nil : Self.albumCoverImage(albumMid),
                duration: TimeInterval((dict["interval"] as? Int) ?? 0),
                qqSongMid: mid
            )
            if let mediaMid = dict["strMediaMid"] as? String, !mediaMid.isEmpty {
                item.qqMediaMid = mediaMid
            }
            return item
        }
    }
}
