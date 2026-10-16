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

    // MARK: - 无签名通用请求（与参考实现同款）

    /// `musicu.fcg` GET 请求：请求体 JSON 整体 URL 编码进 `data=` 参数。
    /// 参考实现验证过：搜索歌手 / 专辑、歌手歌曲 / 专辑这类接口**无需 zzc 签名**，
    /// 走 GET 反而比签名移动端更稳（签名对请求体字节逐字节校验，字段一多容易失配）。
    private func musicuGET(_ body: [String: Any]) async -> [String: Any]? {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let jsonString = String(data: jsonData, encoding: .utf8),
              let encoded = jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.musicuAPI)?data=\(encoded)") else { return nil }
        guard let resp = try? await NetworkClient.shared.get(url.absoluteString, headers: ["Referer": "https://y.qq.com/"]) else { return nil }
        return NetworkClient.jsonObject(resp.data)
    }

    /// OrderedJSON 版本：直接用 `encoded()` 序列化（保序，比 JSONSerialization 更稳）。
    private func musicuGET(_ body: OrderedJSON) async -> [String: Any]? {
        let jsonString = body.encoded()
        guard let encoded = jsonString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.musicuAPI)?data=\(encoded)") else { return nil }
        guard let resp = try? await NetworkClient.shared.get(url.absoluteString, headers: ["Referer": "https://y.qq.com/"]) else { return nil }
        return NetworkClient.jsonObject(resp.data)
    }

    /// 桌面版搜索（`DoSearchForQQMusicDesktop`，无签名）。
    /// 返回原始条目数组；`searchType`：1 = 歌手、2 = 专辑。
    private func desktopSearchItems(_ keyword: String, searchType: Int, limit: Int, page: Int) async -> [[String: Any]] {
        let body: [String: Any] = [
            "comm": ["ct": 19, "cv": 1859, "uin": "0", "format": "json"],
            "req_1": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "query": keyword,
                    "num_per_page": limit,
                    "page_num": page,
                    "search_type": searchType,
                    "grp": 1,
                ],
            ],
        ]
        guard let json = await musicuGET(body),
              let req1 = json["req_1"] as? [String: Any],
              (req1["code"] as? Int) == 0,
              let reqData = req1["data"] as? [String: Any],
              let bodyDict = reqData["body"] as? [String: Any] else { return [] }
        let key = searchType == 1 ? "singer" : (searchType == 2 ? "album" : "song")
        guard let bucket = bodyDict[key] as? [String: Any] else { return [] }
        return bucket["list"] as? [[String: Any]] ?? []
    }

    /// 老 web 搜索接口（无需签名）：歌曲 t=0 / 专辑 t=8。
    private func webSearchItems(_ keyword: String, type: Int, limit: Int, key: String) async -> [[String: Any]] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&w=\(encoded)&n=\(limit)&p=1&t=\(type)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0,
              let dataDict = json["data"] as? [String: Any],
              let bucket = dataDict[key] as? [String: Any] else { return [] }
        return bucket["list"] as? [[String: Any]] ?? []
    }

    // MARK: - 搜索歌曲（search_type = 0）

    func search(keyword: String, limit: Int = 30, page: Int = 1) async throws -> [MusicItem] {
        // 主通道：老 web 接口 search_for_qq_cp（无需签名，实测结果全）。
        // ⚠️ 该接口单页上限 30 条（请求 n=50 也只回 30），翻页靠 p 参数。
        let web = await webSearchSongs(keyword, limit: limit, page: page)
        if !web.isEmpty { return web }
        // 回退：移动端签名接口（无分页，仅首页兜底）
        if page > 1 { return [] }
        return try await searchItems(keyword, searchType: 0, limit: limit, page: 1, key: "item_song")
            .compactMap { parseMobileSong($0) }
    }

    /// `search_for_qq_cp` 歌曲搜索（t=0，无需签名；与参考实现同款）。
    private func webSearchSongs(_ keyword: String, limit: Int, page: Int = 1) async -> [MusicItem] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp?format=json&w=\(encoded)&n=\(limit)&p=\(page)&t=0") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 0,
              let dataDict = json["data"] as? [String: Any],
              let songDict = dataDict["song"] as? [String: Any],
              let list = songDict["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { dict -> MusicItem? in
            guard let mid = dict["songmid"] as? String, !mid.isEmpty else { return nil }
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
            if !albumMid.isEmpty { item.qqAlbumMid = albumMid; item.platformAlbumId = albumMid }
            return item
        }
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
        if !albumMid.isEmpty { item.qqAlbumMid = albumMid; item.platformAlbumId = albumMid }
        return item
    }

    private func parseMobileArtist(_ dict: [String: Any]) -> WellArtistSummary? {
        // ⚠️ Desktop 版搜索（DoSearchForQQMusicDesktop）返回的是**驼峰字段**
        //（singerName / singerMID / singerID），移动端才是小写 —— 键名不齐会把
        // 整页结果全部过滤成空（「QQ 歌手搜索只剩几条 / 歌手主页没专辑」的根因）。
        let mid = (dict["mid"] as? String) ?? (dict["singerMID"] as? String) ?? ""
        let name = (dict["name"] as? String) ?? (dict["singername"] as? String)
            ?? (dict["singerName"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let id = (dict["id"] as? Int) ?? (dict["singerID"] as? Int) ?? abs(mid.hashValue)
        var pic = (dict["pic"] as? String) ?? (dict["singerPic"] as? String) ?? ""
        pic = pic.replacingOccurrences(of: "http://", with: "https://")
        let songNum = (dict["songNum"] as? Int) ?? (dict["songnum"] as? Int) ?? 0
        return WellArtistSummary(
            id: "\(id)", name: name, picURL: pic.isEmpty ? nil : pic,
            platform: .qq, mid: mid.isEmpty ? nil : mid,
            subtitle: songNum > 0 ? "\(songNum) 首单曲" : nil)
    }

    private func parseMobileAlbum(_ dict: [String: Any]) -> WellAlbumSummary? {
        // ⚠️ 同 parseMobileArtist：Desktop 版 / client_search_cp 返回驼峰字段
        //（albumName / albumMID / singerName），键名不齐整页过滤成空。
        let mid = (dict["mid"] as? String) ?? (dict["albummid"] as? String) ?? (dict["albumMID"] as? String) ?? ""
        let name = (dict["name"] as? String) ?? (dict["albumname"] as? String)
            ?? (dict["albumName"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let id = (dict["id"] as? Int) ?? (dict["albumID"] as? Int) ?? (dict["albumid"] as? Int) ?? abs(mid.hashValue)
        var pic = (dict["pic"] as? String) ?? (dict["albumPic"] as? String) ?? ""
        pic = pic.replacingOccurrences(of: "http://", with: "https://")
        if pic.isEmpty, !mid.isEmpty { pic = Self.albumCoverImage(mid) }
        var singerName = ""
        if let singers = dict["singer"] as? [[String: Any]] {
            singerName = singers.compactMap { $0["name"] as? String }.joined(separator: "/")
        }
        if singerName.isEmpty {
            singerName = (dict["singername"] as? String) ?? (dict["singerName"] as? String) ?? ""
        }
        return WellAlbumSummary(
            id: "\(id)", name: name, picURL: pic.isEmpty ? nil : pic,
            artistName: singerName.isEmpty ? "未知歌手" : singerName,
            platform: .qq, albumMid: mid.isEmpty ? nil : mid)
    }

    // MARK: - 歌单导入（Qzone 老接口，无需签名）
    //
    // `fcg_ucc_getcdinfo_byids_cp.fcg` 返回的 songlist 是 PC 老字段风格
    // （songname / songmid / singer[] / albumname / albummid / interval），
    // `parseMobileSong` 对这些字段名都有兜底，直接复用。

    /// 拉取 QQ 音乐歌单详情，返回（歌单名，歌曲列表，封面）。
    func playlistDetail(dissTid: String) async throws -> (name: String, tracks: [MusicItem], coverURL: String?) {
        var comps = URLComponents(string: "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg")!
        comps.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "onlysong", value: "0"),
            URLQueryItem(name: "disstid", value: dissTid),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else {
            throw NetworkClient.NetworkError.noData
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cdlist = json["cdlist"] as? [[String: Any]],
              let cd = cdlist.first else {
            throw NetworkClient.NetworkError.noData
        }

        let name = (cd["dissname"] as? String) ?? "导入的QQ音乐歌单"
        let cover = (cd["logo"] as? String) ?? (cd["headurl"] as? String)
        let songlist = (cd["songlist"] as? [[String: Any]]) ?? []
        let tracks = songlist.prefix(500).compactMap { parseMobileSong($0) }
        return (name, tracks, cover.flatMap { $0.isEmpty ? nil : $0 })
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
    /// - Parameter quality: 音质档位 → filename 前缀（M500 128k / M800 320k / F000 无损 / RS01 Hi-Res）
    func resolvePlayURL(item: MusicItem, quality: WellAudioQuality) async throws -> String {
        guard let mid = item.qqSongMid ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        // media_mid 优先（部分歌曲的音频文件名用 media_mid 而非 songmid）
        let mediaMid = (item.qqMediaMid?.isEmpty == false ? item.qqMediaMid : nil) ?? mid
        // ⚠️ 档位降级链：vkey 接口对「该档位文件不存在 / 无版权 / VIP 限制」一律
        //    返回**空 purl**（实测 HTTP 200 + code 0 但 purl=""），必须降档重试。
        //    一次请求带多个 filename，midurlinfo 按序返回，取第一个非空 purl。
        let candidates: [(String, String)] = [
            (quality.qqFilePrefix, quality.rawValue >= WellAudioQuality.lossless.rawValue ? "flac" : "mp3"),
            ("M800", "mp3"),
            ("M500", "mp3"),
        ]
        let filenames = candidates.map { "\($0.0)\(mediaMid).\($0.1)" }
        let guid = "10000"

        // 该接口的 data 为 JSON 字符串，需先拼好再整体 URL 编码进 query。
        let reqData: [String: Any] = [
            "req_0": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "filename": filenames,
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

        let resp = try await NetworkClient.shared.get(url.absoluteString, headers: ["Referer": "https://y.qq.com/"])
        guard let json = NetworkClient.jsonObject(resp.data),
              let req0 = json["req_0"] as? [String: Any],
              let data = req0["data"] as? [String: Any] else {
            throw NetworkClient.NetworkError.noData
        }
        // ⚠️ sip 域名：实测（2026-10）返回的全是 **http://** 前缀（aqqmusic.tc.qq.com 等），
        //    旧的「找 https 域名，没有就默认 dl.stream.qqmusic.qq.com」兜底拼出来的
        //    https 地址是不可用的（该域名已废弃）。所以现在 https 优先、没有就
        //    直接用返回的 http 域名（ATS 已由 NSAllowsArbitraryLoads 放开）。
        let sips = (data["sip"] as? [String])?.filter { !$0.isEmpty } ?? []
        let sip = sips.first(where: { $0.hasPrefix("https://") }) ?? sips.first
            ?? "http://aqqmusic.tc.qq.com/"
        let base = sip.hasSuffix("/") ? sip : sip + "/"

        // 按请求顺序取第一个非空 purl（vkey 会按 filename 顺序返回）
        let midurlinfos = (data["midurlinfo"] as? [[String: Any]]) ?? []
        for info in midurlinfos {
            guard let purl = info["purl"] as? String, !purl.isEmpty else { continue }
            return base + purl
        }
        // 全部档位都拿不到（VIP / 无版权 / 未登录限制）→ 明确报错，
        // 上层 MusicURLResolver 已有自定义音源优先链，走到这里说明音源也没解析出来。
        throw NetworkClient.NetworkError.noData
    }

    // MARK: - 逐字歌词（QRC）

    /// QQ 逐字歌词：`music.musichallSong.PlayLyricInfo.GetPlayLyricInfo`，
    /// `qrc=1` 时返回 hex 加密的 QRC（3DES + zlib），无需登录（uin=0 即可）。
    /// QQ 音乐逐字歌词接口。
    /// 返回解密后的 QRC 明文；无逐字 / 解析失败返回 nil。
    func wordLyric(songmid: String) async -> String? {
        await playLyricInfo(songmid: songmid)?.qrc
    }

    /// QQ 歌词信息（`GetPlayLyricInfo`）：逐字 QRC + 翻译 LRC。
    ///
    /// 响应字段：`lyric` = hex 加密 QRC；`trans` = **base64 编码的翻译 LRC**
    /// （带 `[ti:]/[ar:]` 等元信息头，时间轴与主歌词一致）。
    /// ⚠️ 必须带 `"trans": 1` 参数，否则该字段不返回。
    func playLyricInfo(songmid: String) async -> (qrc: String?, transLRC: String?)? {
        let body: [String: Any] = [
            "comm": ["uin": 0, "format": 1, "ct": 19, "cv": 0],
            "detail": [
                "module": "music.musichallSong.PlayLyricInfo",
                "method": "GetPlayLyricInfo",
                "param": [
                    "qrc": 1, "qrc_t": 0, "roma": 1, "trans": 1, "guoke": 1,
                    "type": -1, "licenseID": "", "cp": 0, "cv": 0, "ct": 19,
                    "songmid": songmid,
                ],
            ],
        ]
        guard let url = URL(string: Self.musicuAPI) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [
            "User-Agent": Self.mobileUA,
            "Content-Type": "application/json",
            "Referer": "https://y.qq.com/",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10
        guard let resp = try? await NetworkClient.shared.rawRequest(request),
              let json = NetworkClient.jsonObject(resp.data),
              let detail = json["detail"] as? [String: Any],
              let detailData = detail["data"] as? [String: Any] else {
            return nil
        }
        var qrc: String?
        if let qrcFlag = detailData["qrc"] as? Int, qrcFlag == 1,
           let encrypted = detailData["lyric"] as? String, !encrypted.isEmpty {
            qrc = QQQrcDecoder.decrypt(encrypted)
        }
        var transLRC: String?
        if let transRaw = detailData["trans"] as? String, !transRaw.isEmpty {
            // base64 → LRC 明文（解码失败时按明文处理）
            if let data = Data(base64Encoded: transRaw, options: .ignoreUnknownCharacters),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                transLRC = text
            } else {
                transLRC = transRaw
            }
        }
        guard qrc != nil || transLRC != nil else { return nil }
        return (qrc, transLRC)
    }

    /// 解析 QRC 明文 → `WordLyricLine`（复用网易云 YRC 的模型）。
    ///
    /// QRC 行格式：`[行开始ms,行时长ms]字(绝对开始ms,字时长ms)字(…)…`
    /// （注意与 YRC 的区别：QRC 的**字**时间标签在字**后面**，是 `(text,start,dur)`）。
    func parseQrc(_ text: String) -> [WordLyricLine] {
        var result: [WordLyricLine] = []
        guard let lineRegex = try? NSRegularExpression(pattern: #"\[(-?\d+),-?\d+\]([^\r\n]*)"#),
              let wordRegex = try? NSRegularExpression(pattern: #"([^\(\)\r\n]*?)\((-?\d+),(-?\d+)\)"#) else {
            return []
        }
        let nsText = text as NSString
        for lm in lineRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            guard lm.numberOfRanges >= 3 else { continue }
            let lineStartMs = Double(nsText.substring(with: lm.range(at: 1))) ?? 0
            let body = nsText.substring(with: lm.range(at: 2))
            let nsBody = body as NSString
            var words: [WordLyricLine.Word] = []
            var composed = ""
            for wm in wordRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) {
                guard wm.numberOfRanges >= 4 else { continue }
                let piece = nsBody.substring(with: wm.range(at: 1))
                let startMs = Double(nsBody.substring(with: wm.range(at: 2))) ?? 0
                let durMs = Double(nsBody.substring(with: wm.range(at: 3))) ?? 0
                let start = max(0, startMs) / 1000
                let end = start + max(durMs, 1) / 1000
                guard !piece.isEmpty else { continue }
                words.append(WordLyricLine.Word(char: piece, start: start, end: end))
                composed += piece
            }
            guard !words.isEmpty, !composed.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.append(WordLyricLine(
                start: lineStartMs / 1000,
                end: words.last?.end ?? lineStartMs / 1000,
                words: words
            ))
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: - 搜索歌手 / 专辑（对外接口）

    func searchArtists(keyword: String, limit: Int = 30) async throws -> [WellArtistSummary] {
        // 主通道：桌面版无签名接口（实测稳定）
        var list = await desktopSearchItems(keyword, searchType: 1, limit: limit, page: 1)
        // 回退 1：移动端签名接口
        if list.isEmpty {
            list = (try? await searchItems(keyword, searchType: 1, limit: limit, page: 1, key: "item_singer")) ?? []
        }
        // 回退 2：smartbox 联想（结果少但几乎永不挂）
        if list.isEmpty {
            list = await smartboxArtists(keyword, limit: limit)
        }
        return list.compactMap { parseMobileArtist($0) }
    }

    /// smartbox 联想接口兜底（歌手条目在 `data.singer.itemlist`）。
    private func smartboxArtists(_ keyword: String, limit: Int) async -> [[String: Any]] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?format=json&s_from=pc_header&type=1&key=\(encoded)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let singerDict = dataDict["singer"] as? [String: Any],
              let items = singerDict["itemlist"] as? [[String: Any]] else { return [] }
        return Array(items.prefix(limit))
    }

    func searchAlbums(keyword: String, limit: Int = 30) async throws -> [WellAlbumSummary] {
        // 主通道：桌面版无签名接口
        var list = await desktopSearchItems(keyword, searchType: 2, limit: limit, page: 1)
        // 回退 1：老 web 接口 client_search_cp（t=8 专辑）
        if list.isEmpty {
            list = await webSearchItems(keyword, type: 8, limit: limit, key: "album")
        }
        // 回退 2：移动端签名接口
        if list.isEmpty {
            list = (try? await searchItems(keyword, searchType: 2, limit: limit, page: 1, key: "item_album")) ?? []
        }
        return list.compactMap { parseMobileAlbum($0) }
    }

    // MARK: - 歌单搜索（client_music_search_songlist）

    /// 搜索 QQ 歌单。`num_per_page` 上限 30（超过返回空），响应层级不稳定，
    /// 解析时递归收集「有 id 又有名字」的条目。
    func searchPlaylists(keyword: String, limit: Int = 30) async throws -> [WellPlaylistSummary] {
        let target = min(max(limit, 1), 30)
        var comps = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist")!
        comps.queryItems = [
            URLQueryItem(name: "page_no", value: "0"),
            URLQueryItem(name: "num_per_page", value: "\(target)"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "query", value: keyword),
            URLQueryItem(name: "remoteplace", value: "txt.yqq.playlist"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("https://y.qq.com/portal/search.html", forHTTPHeaderField: "Referer")
        req.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = NetworkClient.jsonObject(data) else { return [] }

        var raw: [[String: Any]] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                let hasID = dict["dissid"] != nil || dict["diss_id"] != nil || dict["tid"] != nil || dict["listid"] != nil
                let hasName = dict["diss_name"] != nil || dict["dissname"] != nil || dict["name"] != nil || dict["title"] != nil
                if hasID && hasName { raw.append(dict) }
                for child in dict.values { walk(child) }
            } else if let arr = value as? [Any] {
                for child in arr { walk(child) }
            }
        }
        walk(json)

        var seen = Set<String>()
        let out: [WellPlaylistSummary] = raw.compactMap { item in
            let id = Self.intValue(item["dissid"]) ?? Self.intValue(item["diss_id"])
                ?? Self.intValue(item["tid"]) ?? Self.intValue(item["listid"]) ?? 0
            guard id > 0 else { return nil }
            let name = (item["diss_name"] as? String) ?? (item["dissname"] as? String)
                ?? (item["name"] as? String) ?? (item["title"] as? String) ?? ""
            guard !name.isEmpty, seen.insert("\(id)").inserted else { return nil }
            var cover: String?
            for key in ["diss_cover", "dir_pic_url", "logo", "picurl", "pic_url", "cover", "cover_url", "headurl", "imgurl"] {
                if let value = item[key] as? String, !value.isEmpty {
                    cover = value.replacingOccurrences(of: "http://", with: "https://")
                    break
                }
            }
            let creator = item["creator"] as? [String: Any]
            let creatorName = (creator?["name"] as? String)
                ?? (item["creator_name"] as? String) ?? (item["nickname"] as? String)
            return WellPlaylistSummary(
                id: "\(id)", name: name, coverURL: cover,
                playCount: Self.intValue(item["listennum"]) ?? Self.intValue(item["play_count"]) ?? 0,
                trackCount: Self.intValue(item["song_cnt"]) ?? Self.intValue(item["songnum"])
                    ?? Self.intValue(item["total_song_num"]) ?? 0,
                creatorName: creatorName,
                platform: .qq)
        }
        return Array(out.prefix(target))
    }

    /// 从任意数值类型安全取整。
    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    // MARK: - 歌手歌曲（展开全部 / 详情页用）

    func singerSongs(singerMid: String, begin: Int = 0, num: Int = 30) async throws -> (list: [MusicItem], total: Int, hasMore: Bool) {
        // 主通道：无签名 musicuGET（参考实现同款，comm {ct:24, cv:0} 即可）。
        // 失败再回退签名版（老代码，部分设备签名接口不稳）。
        let plainBody: OrderedJSON = .object([
            ("comm", .object([("ct", .int(24)), ("cv", .int(0))])),
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
        var json: [String: Any]? = await musicuGET(plainBody)
        if json == nil {
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
            json = try? await signedRequest(payload)
        }
        guard let req = json?["req"] as? [String: Any],
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

    // MARK: - 歌手专辑（get_singer_album，无签名 musicuGET）

    func artistAlbums(singerMid: String, page: Int = 1, limit: Int = 30) async throws -> (list: [WellAlbumSummary], total: Int, hasMore: Bool) {
        let body: OrderedJSON = .object([
            ("comm", .object([("ct", .int(24)), ("cv", .int(0))])),
            ("singerAlbum", .object([
                ("method", .string("get_singer_album")),
                ("param", .object([
                    ("singermid", .string(singerMid)),
                    ("order", .string("time")),
                    ("begin", .int((page - 1) * limit)),
                    ("num", .int(limit)),
                    ("exstatus", .int(1)),
                ])),
                ("module", .string("music.web_singer_info_svr")),
            ])),
        ])
        guard let json = await musicuGET(body),
              let singerAlbum = json["singerAlbum"] as? [String: Any],
              let albumData = singerAlbum["data"] as? [String: Any],
              let rawList = albumData["list"] as? [[String: Any]] else {
            return ([], 0, false)
        }
        let total = (albumData["total"] as? Int) ?? (albumData["totalNum"] as? Int) ?? rawList.count
        let list = rawList.compactMap { dict -> WellAlbumSummary? in
            // get_singer_album 返回字段：albumid/album_mid/album_name/singer_name/pub_time/albumtype/song_count/ftype
            let albumID = (dict["albumid"] as? Int) ?? abs(((dict["album_mid"] as? String) ?? "").hashValue)
            let name = (dict["album_name"] as? String) ?? (dict["albumName"] as? String) ?? (dict["name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let mid = (dict["album_mid"] as? String) ?? (dict["albumMID"] as? String) ?? (dict["mid"] as? String) ?? ""
            let pic = mid.isEmpty ? nil : Self.albumCoverImage(mid, size: 480)
            let singerName = (dict["singer_name"] as? String) ?? (dict["singerName"] as? String) ?? ""
            // pub_time 是秒级时间戳 → 存毫秒（与网易云对齐）
            let pubSeconds = (dict["pub_time"] as? Int) ?? (dict["publishTime"] as? Int) ?? 0
            let albumType = (dict["albumtype"] as? String) ?? (dict["album_type"] as? String) ?? (dict["albumType"] as? String) ?? ""
            let songCount = (dict["song_count"] as? Int) ?? (dict["songCount"] as? Int) ?? (dict["songcount"] as? Int) ?? (dict["total"] as? Int) ?? (dict["count"] as? Int) ?? (dict["size"] as? Int) ?? 0
            let ftype = (dict["ftype"] as? Int) ?? 0
            var subType = "专辑"
            if albumType.contains("EP") || albumType.contains("单曲") || ftype == 10 {
                subType = songCount <= 1 ? "单曲" : "EP"
            } else if songCount == 1 {
                subType = "单曲"
            } else if songCount > 1 && songCount <= 5 {
                subType = "EP"
            }
            return WellAlbumSummary(
                id: "\(albumID)", name: name, picURL: pic,
                artistName: singerName.isEmpty ? "未知歌手" : singerName,
                platform: .qq, albumMid: mid.isEmpty ? nil : mid,
                albumType: subType,
                publishTime: pubSeconds > 0 ? pubSeconds * 1000 : nil)
        }
        return (list, total, list.count < total)
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
