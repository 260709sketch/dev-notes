import Foundation

/// 保序 JSON 构造器。
///
/// Swift 标准库的 `JSONSerialization` 对字典键顺序不做保证，而 QQ 移动端接口的
/// `sign` 是对**请求体原始字节**做 SHA1 校验的 —— 键顺序一变签名即失效（服务端
/// 返回空结果）。这里显式按插入顺序拼字节，保证签名与 httpsBody 完全一致。
///
/// 用法：
/// ```swift
/// let body: OrderedJSON = .object([
///     ("comm", .object([...])),
///     ("req",  .object([...])),
/// ])
/// body.encoded()   // → 稳定、可复现的 JSON 字符串
/// ```
indirect enum OrderedJSON {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])
    /// 按插入顺序序列化（无多余空格，与 JS `JSON.stringify` 输出一致）。
    func encoded() -> String {
        switch self {
        case .string(let s):
            return Self.quote(s)
        case .int(let i):
            return String(i)
        case .double(let d):
            return d == d.rounded() ? String(Int(d)) : String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .array(let items):
            return "[" + items.map { $0.encoded() }.joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { "\(Self.quote($0.0)):\($0.1.encoded())" }.joined(separator: ",") + "}"
        }
    }

    /// JSON 字符串转义（与 JS `JSON.stringify` 一致的最小转义集）。
    private static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }
}

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

    private func mobileComm() -> OrderedJSON {
        .object([
            ("ct", .string("11")), ("cv", .string("14090508")), ("v", .string("14090508")),
            ("tmeAppID", .string("qqmusic")),
            ("phonetype", .string("EBG-AN10")), ("deviceScore", .string("553.47")),
            ("devicelevel", .string("50")), ("newdevicelevel", .string("20")),
            ("rom", .string("HuaWei/EMOTION/EmotionUI_14.2.0")), ("os_ver", .string("12")),
            ("OpenUDID", .string("0")), ("OpenUDID2", .string("0")), ("QIMEI36", .string("0")),
            ("udid", .string("0")), ("chid", .string("0")), ("aid", .string("0")),
            ("oaid", .string("0")), ("taid", .string("0")), ("tid", .string("0")),
            ("wid", .string("0")), ("uid", .string("0")), ("sid", .string("0")),
            ("modeSwitch", .string("6")), ("teenMode", .string("0")), ("ui_mode", .string("2")),
            ("nettype", .string("1020")), ("v4ip", .string("")),
        ])
    }

    /// 移动端签名请求：POST musics.fcg?sign=zzc...
    ///
    /// 关键：签名基于**实际发送的 JSON 字节**，服务端逐字节校验。Swift 的
    /// `JSONSerialization` 对字典的键顺序**不保证稳定**（同一字典多次序列化可能不同），
    /// 所以这里用 `OrderedJSON` 手动按固定顺序拼字节 —— 签名与 httpBody 共用同一份
    /// Data，绝不二次序列化。
    private func signedRequest(_ payload: OrderedJSON) async throws -> [String: Any]? {
        let bodyData = Data(payload.encoded().utf8)
        let bodyString = payload.encoded()
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
        let payload: OrderedJSON = .object([
            ("comm", mobileComm()),
            ("req", .object([
                ("module", .string("music.search.SearchCgiService")),
                ("method", .string("DoSearchForQQMusicMobile")),
                ("param", .object([
                    ("search_type", .int(searchType)),
                    ("searchid", .string(String(Int.random(in: 100_000_000_000_000...999_999_999_999_999)))),
                    ("query", .string(keyword)),
                    ("page_num", .int(page)),
                    ("num_per_page", .int(limit)),
                    ("highlight", .int(0)),
                    ("nqc_flag", .int(0)),
                    ("multi_zhida", .int(0)),
                    ("cat", .int(2)),
                    ("grp", .int(1)),
                    ("sin", .int(0)),
                    ("sem", .int(0)),
                ])),
            ])),
        ])
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
        let title = (dict["title"] as? String) ?? (dict["name"] as? String)
            ?? (dict["songname"] as? String) ?? "未知歌曲"
        var singers = (dict["singer"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        if singers.isEmpty, let single = dict["singername"] as? String, !single.isEmpty {
            singers = single.components(separatedBy: "&").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let albumDict = dict["album"] as? [String: Any]
        let albumName = (albumDict?["name"] as? String) ?? (dict["albumname"] as? String)
        let albumMid = (albumDict?["mid"] as? String) ?? (dict["albummid"] as? String) ?? ""
        let fileDict = dict["file"] as? [String: Any]
        let mediaMid = (fileDict?["media_mid"] as? String) ?? (dict["strMediaMid"] as? String) ?? ""
        // interval 可能返回 Int 或 Double
        let interval = TimeInterval((dict["interval"] as? Int)
            ?? (dict["interval"] as? Double).map { Int($0) } ?? 0)

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

    // MARK: - 播放地址（vkey.GetVkeyServer / CgiGetVkey，与 RN 版对齐）

    /// 取播放直链。此前用 `fcg_music_express_mobile3.fcg` 已失效（该接口早已下线，
    /// 返回的 vkey 为空 → 播放器拿不到地址）。改用官方仍在用的
    /// `vkey.GetVkeyServer / CgiGetVkey`，一次请求直接返回 `purl`（含 vkey 的完整路径）。
    ///
    /// - Parameter highQuality: true 取 320K MP3（M800），false 取 128K MP3（M500）
    func resolvePlayURL(item: MusicItem, highQuality: Bool) async throws -> String {
        guard let mid = item.qqSongMid ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        // media_mid 优先（部分歌曲的音频文件名用 media_mid 而非 songmid）
        let mediaMid = (item.qqMediaMid?.isEmpty == false ? item.qqMediaMid : nil) ?? mid
        let prefix = highQuality ? "M800" : "M500"
        let filename = "\(prefix)\(mediaMid).mp3"
        let guid = "10000"

        // 该接口的 data 为 JSON 字符串，需先拼好再整体 URL 编码进 query。
        let reqData: [String: Any] = [
            "req_0": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "filename": [filename],
                    "guid": guid,
                    "songmid": [mid],
                    "songtype": [0],
                    "uin": "0",
                    "loginflag": 1,
                    "platform": "20",
                ],
            ],
            "loginUin": "0",
            "comm": ["uin": "0", "format": "json", "ct": 24, "cv": 0],
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: reqData),
              let jsonString = String(data: jsonData, encoding: .utf8),
              let encoded = jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&data=\(encoded)") else {
            throw NetworkClient.NetworkError.invalidURL
        }

        let resp = try await NetworkClient.shared.get(url, headers: ["Referer": "https://y.qq.com/"])
        guard let json = NetworkClient.jsonObject(resp.data),
              let req0 = json["req_0"] as? [String: Any],
              let data = req0["data"] as? [String: Any],
              let purl = (data["midurlinfo"] as? [[String: Any]])?.first?["purl"] as? String,
              !purl.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        // purl 形如 `M800xxxx.mp3?vkey=...`，拼 siren 域名即完整可播地址
        let sip = (data["sip"] as? [String])?.first(where: { $0.hasPrefix("https://") }) ?? "https://dl.stream.qqmusic.qq.com/"
        let base = sip.hasSuffix("/") ? sip : sip + "/"
        return base + purl
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
        let payload: OrderedJSON = .object([
            ("comm", mobileComm()),
            ("req", .object([
                ("module", .string("musichall.song_list_server")),
                ("method", .string("GetSingerSongList")),
                ("param", .object([
                    ("singerMid", .string(singerMid)),
                    ("begin", .int(begin)),
                    ("num", .int(num)),
                    ("order", .int(1)),
                ])),
            ])),
        ])
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
