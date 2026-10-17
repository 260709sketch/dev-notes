import Foundation

/// 网易云音乐 API。
///
/// ⚠️ **通道说明（2026-10-16 复测，改动前务必先读这段）**
///
/// 两条通道都可用，按接口类型分工：
///
/// * **weapi（`/weapi/*`，AES + RSA 加密）**：登录族接口（二维码 / 短信 / 手机号 /
///   听歌排行）走这条。2026-10-16 实测：`weapi/login/qrcode/unikey` 返回
///   `code:200 + unikey`、轮询返回 `801`、合规号段 `weapi/sms/captcha/sent`
///   返回 `code:200`（真能下发验证码）—— 通道完全正常。
///   weapi 请求带设备指纹 Cookie（nuid / deviceId / NMTID），风控评分低于裸明文，
///   与参考实现保持一致。
///   ⚠️ 历史误判：本文件曾断言「weapi 已被服务端停用、恒返回空体」—— 那是加密
///   参数没配对导致的假象，已作废。谁再改登录相关代码，先跑一遍探针脚本确认。
///
/// * **明文（`api/*`）**：搜索、歌单、歌曲详情这类公开接口走这条，省一次加解密。
///   账号资料 `api/nuser/account/get` 也是明文 GET（参考实现同款）。
///
/// 加密实现见 `NeteaseWeapi.swift`（AES-128-CBC 双层 + 密钥反转的 RAW RSA）。
final class NeteaseMusicAPI {
    static let shared = NeteaseMusicAPI()

    init() {}

    // MARK: 通道（明文 api/）

    /// 网易云**明文**接口请求。
    ///
    /// - Parameter path: 以 `api/` 开头的路径，如 `api/toplist`。
    /// - Parameter params: 会被编码成 `application/x-www-form-urlencoded` 表单。
    ///   `Bool` 会编码为 `true` / `false`（网易云不少接口的 `total` 是布尔）。
    ///
    /// 与 `weapiRequest` 的分工见文件头部说明：公开读接口走明文（省一次加解密），
    /// 登录族 / 风控敏感接口走 weapi。两条通道都正常，别再说「加密通道已停用」。
    private static func apiRequest<T: Decodable>(_ path: String,
                                                 params: [String: Any] = [:],
                                                 type: T.Type,
                                                 headers extraHeaders: [String: String] = [:]) async throws -> T {
        var finalParams = params
        // 网易云对「会改状态」的接口（发验证码 / 登录 / 收藏）要求表单里的 `csrf_token`
        // 与 Cookie 里的 `__csrf` 一致。调用点大多写死空串，这里统一补一次 ——
        // 少了它会直接被判成非法请求，表现为「输入验证码后报错」这种莫名其妙的失败。
        let providedCSRF = (finalParams["csrf_token"] as? String) ?? ""
        if providedCSRF.isEmpty,
           let cookieCSRF = NeteaseSession.shared.cookie(named: "__csrf"), !cookieCSRF.isEmpty {
            finalParams["csrf_token"] = cookieCSRF
        }

        let body = Data(formEncode(finalParams).utf8)
        let resp = try await NetworkClient.shared.postRaw(
            "https://music.163.com/\(path)",
            body: body,
            contentType: "application/x-www-form-urlencoded",
            headers: {
                var h: [String: String] = [
                    "Referer": "https://music.163.com/",
                    "Origin": "https://music.163.com",
                    // 登录后所有请求都要带票据，否则拿到的是匿名数据
                    // （发现页 / 每日推荐 / 我喜欢 这类会直接空手而归）。
                    "Cookie": NeteaseSession.shared.cookieHeader,
                ]
                for (k, v) in extraHeaders { h[k] = v }
                return h
            }()
        )
        // 服务端可能在响应头里续期票据（登录成功后 `MUSIC_U` 就是走这里下发的），
        // 顺手吸收掉。字段名大小写不敏感 —— `allHeaderFields` 给的 casing 不保证。
        if let setCookie = headerValue(resp.headers, "Set-Cookie") {
            NeteaseSession.shared.absorb(setCookieHeaders: [setCookie])
        }
        // 显式校验状态码：否则 403/5xx 会被后面的解码失败吞掉，
        // 界面上只剩一句「没有返回数据」，排查时看不出真因。
        guard (200..<300).contains(resp.statusCode) else {
            throw NetworkClient.NetworkError.badStatus(resp.statusCode)
        }
        guard let decoded = NetworkClient.decode(type, from: resp.data) else {
            throw NetworkClient.NetworkError.noData
        }
        return decoded
    }

    // MARK: 通道（weapi / 加密请求，登录态接口首选）

    /// weapi 请求的 Cookie 风格。
    private enum WeapiCookieStyle {
        /// 会话 Cookie + 设备指纹（默认）：给读接口用，风控评分更低。
        case device
        /// 只发会话 Cookie（+ `os=pc` / `appver=3.1.17`）。
        ///
        /// ★ 2026-10-16 用户「二维码/手机号登录照搬参考实现」→ 登录族一律用这个：
        /// 参考实现登录时只发 `MUSIC_U` / `__csrf` / `NMTID` + 这两个标识，
        /// **不带** `_ntes_nuid` / `deviceId` / `WNMCID` 那套浏览器设备指纹 ——
        /// 设备指纹是「网页访客」特征，混进登录请求会让服务端把这次会话
        /// 记成另一个设备，扫码头与轮询头对不上（票据就不落回来了）。
        case session
    }

    /// weapi POST（`https://music.163.com/weapi/…`）。
    ///
    /// - path 一律以 `/api/` 开头：内部去掉 `/api` 前缀拼到 `/weapi` 之后（与客户端一致）。
    /// - 加密：`NeteaseWeapi.weapi`（AES-CBC 双层 + **密钥反转后的无填充 RSA**）。
    /// - Cookie 见 `WeapiCookieStyle`；payload 的 `csrf_token` 与 Cookie 里的 `__csrf`
    ///   保持一致，且非空时**同时拼进 URL query**（参考实现同款写法，服务端会校验两处一致）。
    private static func weapiRequest<T: Decodable>(_ path: String,
                                                   params: [String: Any],
                                                   type: T.Type,
                                                   cookieStyle: WeapiCookieStyle = .device) async throws -> T {
        var suffix = path.hasPrefix("/api") ? String(path.dropFirst(4)) : path
        var payload = params
        if payload["csrf_token"] == nil {
            payload["csrf_token"] = NeteaseSession.shared.cookie(named: "__csrf") ?? ""
        }
        let csrf = (payload["csrf_token"] as? String) ?? ""
        if !csrf.isEmpty {
            suffix += (suffix.contains("?") ? "&" : "?") + "csrf_token=\(csrf)"
        }
        let enc = NeteaseWeapi.weapi(payload)
        guard let paramsValue = enc["params"], !paramsValue.isEmpty,
              let encSecKey = enc["encSecKey"], !encSecKey.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        let form = "params=\(escapeForm(paramsValue))&encSecKey=\(escapeForm(encSecKey))"
        let cookie: String
        switch cookieStyle {
        case .device: cookie = neteaseWebCookieHeader()
        case .session:
            // ★ 2026-10-17：未登录时 session cookie 为空 → 心动等接口直接 -301 失败
            //   （比 device 匿名态更差）。登录才用 session，否则回落匿名设备指纹。
            cookie = NeteaseSession.shared.isLoggedIn
                ? NeteaseSession.shared.cookieHeader
                : neteaseWebCookieHeader()
        }
        let resp = try await NetworkClient.shared.postRaw(
            "https://music.163.com/weapi\(suffix)",
            body: Data(form.utf8),
            contentType: "application/x-www-form-urlencoded",
            headers: [
                "Referer": "https://music.163.com/",
                "Origin": "https://music.163.com",
                "Cookie": cookie,
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            ]
        )
        if let setCookie = headerValue(resp.headers, "Set-Cookie") {
            NeteaseSession.shared.absorb(setCookieHeaders: [setCookie])
        }
        guard (200..<300).contains(resp.statusCode) else {
            throw NetworkClient.NetworkError.badStatus(resp.statusCode)
        }
        guard let decoded = NetworkClient.decode(type, from: resp.data) else {
            throw NetworkClient.NetworkError.noData
        }
        return decoded
    }

    /// weapi 请求的完整 Cookie：设备指纹（持久化）+ 登录票据。
    ///
    /// ⚠️ 两个坑（都实测过）：
    /// 1. **NMTID 必须稳定**：每次请求都换一个新 NMTID，等于每秒换一台设备，
    ///    风控立刻盯上。服务端下发过（已存进会话）就原样复用，没下发过才自己补。
    /// 2. **同一个 Key 不能在 Cookie 头里出现两次**：设备指纹列表末尾原来直接拼
    ///    会话 Cookie，而会话里可能已存有 NMTID —— 同名撞车时服务端取哪个全看心情。
    ///    所以这里按 Key 去重后再拼。
    /// ⚠️ 设备 cookie 缺失时服务端可能直接忽略登录态请求（返回空数据）。
    private static func neteaseWebCookieHeader() -> String {
        let defaults = UserDefaults.standard
        func deviceValue(_ key: String, generate: () -> String) -> String {
            if let value = defaults.string(forKey: key), !value.isEmpty { return value }
            let value = generate()
            defaults.set(value, forKey: key)
            return value
        }
        let nuid = deviceValue("netease.device.nuid") { randomHex(length: 32) }
        let deviceId = deviceValue("netease.device.deviceId") { randomHex(length: 26) }
        let wnMcid = deviceValue("netease.device.wnmcid") {
            let random = String((0..<6).compactMap { _ in "abcdefghijklmnopqrstuvwxyz".randomElement() })
            return "\(random).\(Int(Date().timeIntervalSince1970 * 1000)).01.0"
        }
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        var parts = [
            "__remember_me=true",
            "ntes_kaola_ad=1",
            "_ntes_nuid=\(nuid)",
            "_ntes_nnid=\(nuid),\(ts)",
            "WNMCID=\(wnMcid)",
            "WEVNSM=1.0.0",
            "deviceId=\(deviceId)",
            "os=pc",
            "channel=netease",
            "appver=3.1.17.204416",
        ]
        // 会话 Cookie（登录票据 + 服务端下发的 NMTID / __csrf），按 Key 去重后拼接
        var emitted = Set(parts.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        for piece in NeteaseSession.shared.cookieHeader.split(separator: "; ") {
            let text = String(piece)
            guard let name = text.split(separator: "=", maxSplits: 1).first.map(String.init),
                  !name.isEmpty, !emitted.contains(name) else { continue }
            emitted.insert(name)
            parts.append(text)
        }
        // 服务端没给过 NMTID 时才自己补一个
        if !emitted.contains("NMTID") {
            parts.append("NMTID=\(randomHex(length: 16))")
        }
        return parts.joined(separator: "; ")
    }

    private static func randomHex(length: Int) -> String {
        let chars = "0123456789abcdef"
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    // MARK: 通道（eapi / interface.music.163.com）

    /// eapi POST（`interface.music.163.com/eapi<path>`，params=hex 表单）。
    ///
    /// 与明文 `apiRequest` 并存：听歌排行 `/api/v1/play/record`、听歌上报
    /// `/api/feedback/weblog` 这些**登录态强绑定**的接口，明文 `api/*` 拿不到，
    /// 必须走 eapi（参考源码 `neteaseScrobble.js` 同款）。eapi 加密体里要带
    /// 客户端 header（`NeteaseCrypto.eapiHeaderPayload`），否则服务端静默忽略。
    private static func eapiRequest<T: Decodable>(_ path: String,
                                                  params: [String: Any],
                                                  type: T.Type,
                                                  headers extraHeaders: [String: String] = [:]) async throws -> T {
        guard let body = NeteaseCrypto.makeEapiBody(path: path, params: params) else {
            throw NetworkClient.NetworkError.invalidURL
        }
        // 默认头可被调用点覆盖（听歌上报要换成桌面客户端特征的 Cookie / UA，见 `sendWeblog`）。
        var headers: [String: String] = [
            "Referer": "https://music.163.com/",
            "Origin": "https://music.163.com",
            "Cookie": NeteaseSession.shared.cookieHeader,
        ]
        headers.merge(extraHeaders) { _, new in new }
        let resp = try await NetworkClient.shared.postRaw(
            "https://interface.music.163.com/eapi\(path)",
            body: Data(body.utf8),
            contentType: "application/x-www-form-urlencoded",
            headers: headers
        )
        guard (200..<300).contains(resp.statusCode) else {
            throw NetworkClient.NetworkError.badStatus(resp.statusCode)
        }
        guard let decoded = NetworkClient.decode(type, from: resp.data) else {
            throw NetworkClient.NetworkError.noData
        }
        return decoded
    }

    /// 取响应头（键名大小写不敏感）。
    private static func headerValue(_ headers: [String: String], _ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let target = name.lowercased()
        for (key, value) in headers where key.lowercased() == target { return value }
        return nil
    }

    /// 参数 → `a=1&b=2`，键按字典序排列（便于复现问题），值全部严格百分号编码。
    private static func formEncode(_ params: [String: Any]) -> String {
        params.keys.sorted().compactMap { key -> String? in
            guard let value = formValue(params[key]) else { return nil }
            return "\(escapeForm(key))=\(escapeForm(value))"
        }
        .joined(separator: "&")
    }

    /// 表单值编码：只接受标量，其他类型（数组/字典）直接跳过。
    private static func formValue(_ any: Any?) -> String? {
        switch any {
        case let string as String: return string
        case let bool as Bool: return bool ? "true" : "false"
        case let int as Int: return String(int)
        case let double as Double: return String(double)
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func escapeForm(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    // MARK: 解码模型

    /// 歌曲（搜索结果 / 歌单 / 专辑 / 歌手热歌 共用结构）
    private struct Song: Decodable {
        var id: Int?
        var name: String?
        // weapi 通道用 ar/al；明文 api/song/detail 用 artists/album（2026-10-16 问题1：
        // 只认 al/ar 时，明文兜底回来的歌「有回包但封面/歌手全 nil」，
        // 发现页「我喜欢的音乐」卡因此永远落在默认灰心图上）。
        var ar: [Artist]?
        var artists: [Artist]?
        var al: Album?
        var album: Album?
        var dt: Int?
        /// 网易云付费标记：1 = VIP 歌曲、4 = 购买专辑、8 = 低音质免费。仅用于列表行 VIP 徽章。
        var fee: Int?
        /// MV id（0 = 无 MV；2026-10-16 用户问题6）
        var mv: Int?
        struct Artist: Decodable { var name: String? }
        struct Album: Decodable {
            var id: Int?
            var name: String?
            var picUrl: String?
        }

        /// weapi 优先，明文兜底。
        var effectiveAlbum: Album? { al ?? album }
        var effectiveArtists: [Artist]? { (ar?.isEmpty == false) ? ar : artists }
    }

    private struct ArtistItem: Decodable {
        var id: Int?
        var name: String?
        var picUrl: String?
        var musicSize: Int?
        var albumSize: Int?
    }

    private struct AlbumItem: Decodable {
        var id: Int?
        var name: String?
        var picUrl: String?
        var size: Int?
        /// 专辑类型（「专辑 / EP / 单曲」；歌手专辑接口返回，搜索接口可能缺省）
        ///
        /// ⚠️ 中英混合：「专辑」是中文，「Single / EP」是英文（周杰伦《即兴曲》
        /// type="Single"）—— 判 EP/单曲时必须同时匹配英文，见 `WellAlbumSummary.isEPOrSingle`。
        var type: String?
        /// 发行时间（**毫秒**时间戳；歌手专辑接口返回，搜索接口可能缺省）
        var publishTime: Int?
        var artist: Artist?
        struct Artist: Decodable { var name: String? }
    }

    private struct PlaylistItem: Decodable {
        var id: Int?
        var name: String?
        /// 搜索 / 歌单接口用这个字段
        var coverImgUrl: String?
        /// 个性化推荐接口（`api/personalized/playlist`）**只给 `picUrl`**，没有 `coverImgUrl`
        var picUrl: String?
        /// ⚠️ 类型故意是 `Double` 而不是 `Int`：同一个字段在不同接口下的 JSON 字面量不一样 ——
        /// `cloudsearch` 给整数 `33762588`，`api/personalized/playlist` 给浮点 `28266136.0`。
        /// 用 `Int?` 接浮点有解码失败风险，一旦失败**整条响应都解不出来**（整个货架凭空消失），
        /// 所以统一用 `Double?` 接住，映射时再转 `Int`。
        var playCount: Double?
        var trackCount: Int?
        var creator: Creator?
        struct Creator: Decodable { var nickname: String? }
    }

    private struct SearchResponse: Decodable {
        var code: Int?
        var result: Result?
        var songCount: Int?
        struct Result: Decodable {
            var songs: [Song]?
            var artists: [ArtistItem]?
            var albums: [AlbumItem]?
            var playlists: [PlaylistItem]?
            var songCount: Int?
        }
    }

    private struct ArtistAlbumsResponse: Decodable {
        var code: Int?
        var hotAlbums: [AlbumItem]?
        /// 是否还有下一页。该接口**没有 total 字段**，offset 分页只能靠它 + 空页判断。
        var more: Bool?
        /// 平台侧歌手信息：`albumSize` 是平台展示的真实专辑总数（周杰伦 = 44）。
        var artist: AlbumsArtist?
        struct AlbumsArtist: Decodable {
            var albumSize: Int?
            var musicSize: Int?
        }
    }

    private struct PlaylistDetailResponse: Decodable {
        var code: Int?
        var playlist: Body?
        struct Body: Decodable {
            var name: String?
            var coverImgUrl: String?
            var description: String?
            var tracks: [Song]?
            var trackIds: [TrackID]?
            /// 创建者（2026-10-16 用户 问题2：歌单页标题下要显示创建者头像 + 昵称）
            var creator: Creator?
            struct TrackID: Decodable { var id: Int? }
            struct Creator: Decodable {
                var nickname: String?
                var avatarUrl: String?
            }
        }
    }

    private struct SongsDetailResponse: Decodable {
        var songs: [Song]?
    }

    private struct AlbumDetailResponse: Decodable {
        var code: Int?
        var songs: [Song]?
    }

    private struct ArtistDetailResponse: Decodable {
        var code: Int?
        var hotSongs: [Song]?
        /// ★ 2026-10-17：weapi v1/artist 同时回 artist 对象（头像/背景）。
        ///   此前只取 hotSongs → 歌手页头像只能靠搜索/专辑封面兜，经常没有。
        var artist: ArtistObject?

        struct ArtistObject: Decodable {
            var name: String?
            var picUrl: String?
            var img1v1Url: String?
            var cover: String?
            var avatar: String?
            var briefDesc: String?
            var musicSize: Int?
            var songSize: Int?
            var followed: Bool?
        }
    }

    /// 歌手页需要的完整信息（头像 + 热门歌曲）。
    struct ArtistProfile {
        var name: String?
        var avatarURL: String?
        var briefDesc: String?
        var hotSongs: [MusicItem]
        var totalSongCount: Int = 0
        var isFollowed: Bool = false
    }

    /// 播放地址响应。
    ///
    /// ⚠️ `data` 的形态**三种都出现过**（2026-10-16 实测）：
    /// 1. `player/url/v1` → **数组**（每曲一项）；
    /// 2. `download/url/v1` → **单对象**（云盘文件直链就走这个）；
    /// 3. 风控响应（`code:-462`）→ 带 `verifyUrl` 的**单对象**。
    /// 早期只按数组解码，遇到 2/3 整条失败 → 表现为「没有返回数据」。
    private struct URLResponse: Decodable {
        var code: Int?
        var message: String?
        var data: URLPayload?
        /// 是否触发了风控滑块验证（`code:-462`）
        var isRiskControl: Bool {
            code == -462 || data?.single?.verifyUrl != nil
        }
        struct URLPayload: Decodable {
            var items: [URLItem]?
            var single: URLItem?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let array = try? container.decode([URLItem].self) {
                    items = array
                } else if let object = try? container.decode(URLItem.self) {
                    single = object
                }
            }
        }
        struct URLItem: Decodable {
            var url: String?
            var br: Int?
            var level: String?
            /// 单曲级别状态码（200 = 有地址）
            var code: Int?
            /// 风控验证页地址（出现即表示被风控）
            var verifyUrl: String?
        }
    }

    // MARK: 发现页的响应结构

    private struct PersonalizedPlaylistResponse: Decodable {
        var code: Int?
        var result: [PlaylistItem]?
    }

    /// `api/top/playlist`（歌单广场）响应
    private struct TopPlaylistResponse: Decodable {
        var code: Int?
        var playlists: [PlaylistItem]?
        var more: Bool?
    }

    /// `api/playlist/highquality/list`（精品歌单）响应
    private struct HighQualityResponse: Decodable {
        var playlists: [PlaylistItem]?
        var more: Bool?
        var lasttime: Int?
    }

    /// 网易云图片 URL 归一化：剥掉原始查询参数，统一拼 `?param=WxH` 重取。
    ///
    /// ⚠️ 列表接口返回的 `coverImgUrl` 尾部常带 `thumbnail=140y140` 这类小图参数，
    /// 直接用会明显模糊；服务端支持用 `param` 覆盖并重取任意尺寸。
    /// 非网易云图床的 URL 原样返回。
    static func neteaseCover(_ url: String?, size: Int = 512) -> String? {
        guard let url, !url.isEmpty else { return nil }
        guard url.contains("music.126.net") else { return url }
        let base = url.components(separatedBy: "?").first ?? url
        return "\(base)?param=\(size)y\(size)"
    }

    /// `api/discovery/simiSong`（相似歌曲）响应
    private struct SimiSongResponse: Decodable {
        var code: Int?
        var songs: [Song]?
    }

    /// `api/artist/sublist`（关注歌手）响应
    private struct FollowedArtistsResponse: Decodable {
        var code: Int?
        var count: Int?
        var data: [FollowedArtist]?
        struct FollowedArtist: Decodable {
            var id: Int?
            var name: String?
            var picUrl: String?
        }
    }

    private struct ToplistItem: Decodable {
        var id: Int?
        var name: String?
        var coverImgUrl: String?
        var updateFrequency: String?
    }

    private struct ToplistResponse: Decodable {
        var code: Int?
        var list: [ToplistItem]?
    }

    private struct NewAlbumsResponse: Decodable {
        var code: Int?
        var albums: [AlbumItem]?
    }

    private struct TopArtistsResponse: Decodable {
        var code: Int?
        var list: Body?
        struct Body: Decodable { var artists: [ArtistItem]? }
    }

    // MARK: 每日推荐 / 私人漫游 / 心动模式 的响应模型

    private struct DailyRecommendResponse: Decodable {
        var code: Int?
        var data: Body?
        struct Body: Decodable { var dailySongs: [Song]? }
    }

    /// 私人 FM 的歌曲（**两套格式都可能出现**，见 `mapFMTrack` 的说明）
    private struct FMTrack: Decodable {
        var id: Int?
        var name: String?
        /// 毫秒（老格式字段名）
        var duration: Int?
        /// 毫秒（新格式字段名，与搜索 / 日推同一套 `ar` / `al` / `dt`）
        var dt: Int?
        var artists: [Artist]?
        var album: Album?
        var ar: [Song.Artist]?
        var al: Song.Album?
        struct Artist: Decodable { var name: String? }
        struct Album: Decodable {
            var name: String?
            var picUrl: String?
        }
    }

    private struct FMResponse: Decodable {
        var code: Int?
        var data: [FMTrack]?
    }

    private struct IntelligenceResponse: Decodable {
        var code: Int?
        var message: String?
        var data: [Item]?
        struct Item: Decodable { var songInfo: Song? }
    }

    // MARK: 登录相关模型

    private struct QRKeyResponse: Decodable {
        var code: Int?
        var unikey: String?
    }

    private struct QRPollResponse: Decodable {
        var code: Int?
        var message: String?
        var nickname: String?
        var avatarUrl: String?
        /// 少数响应会把票据放在 body 里（多数走 `Set-Cookie`，由传输层吸收）
        var cookie: String?
    }

    /// 只关心业务码的响应（验证码发送、退出登录等）。
    private struct CodeResponse: Decodable {
        var code: Int?
        var message: String?
        var msg: String?
    }

    /// MV 搜索（明文 `api/cloudsearch/pc`，type=1004）。
    ///
    /// ⚠️ cloudsearch 对「歌手名」关键词的相关度会把**访谈/预告/花絮**排在歌曲 MV
    /// 前面（与官方 App 的观感明显不同）——这里做轻量净化：剔除访谈类标题与
    /// 30 秒以下的预告片段；其余保持接口原顺序（不做重排，避免引入更大偏差）。
    func searchMVs(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [WellMVSummary] {
        var results = try await searchMVsRaw(keyword: keyword, limit: limit, offset: offset)
        // ★ 2026-10-15 用户：「搜 playboicarti 只有两个」——搜索词的空格/大小写
        //   不规范时结果骤减（实测 playboicarti=4 条 vs Playboi Carti=61 条）。
        //   与官方一致地做**搜索建议纠错**：结果过少时用建议接口拿规范写法再搜并合并。
        if results.count < 5 {
            if let corrected = await correctedMVKeyword(for: keyword), corrected != keyword {
                if let more = try? await searchMVsRaw(keyword: corrected, limit: limit, offset: offset) {
                    var seen = Set(results.map(\.id))
                    for mv in more where !seen.contains(mv.id) {
                        seen.insert(mv.id)
                        results.append(mv)
                    }
                }
            }
        }
        return results
    }

    private func searchMVsRaw(keyword: String, limit: Int, offset: Int) async throws -> [WellMVSummary] {
        let params: [String: Any] = ["s": keyword, "type": 1004,
                                     "limit": limit, "offset": offset, "total": true]
        let resp: MVCloudSearchResponse = try await Self.apiRequest(
            "api/cloudsearch/pc", params: params, type: MVCloudSearchResponse.self)
        return (resp.result?.mvs ?? []).compactMap { mv in
            guard let id = mv.id else { return nil }
            let name = mv.name ?? ""
            let duration = TimeInterval(mv.duration ?? 0) / 1000
            guard !Self.isNoisyMVTitle(name), duration >= 30 else { return nil }
            return WellMVSummary(
                id: "\(id)",
                name: name,
                coverURL: Self.neteaseCover(mv.cover, size: 500),
                artistName: mv.artistName,
                duration: duration,
                playCount: mv.playCount ?? 0,
                platform: .netease)
        }
    }

    /// 搜索关键词联想（`api/search/suggest/web`）——输入即出候选词
    /// （2026-10-16 用户：像平台那样打一个字就有关键词）。
    /// 返回去重后的候选：歌手名 + 歌名，最多 8 条。
    func searchSuggestions(for keyword: String) async -> [String] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let params: [String: Any] = ["s": trimmed, "limit": 8]
        guard let resp: SuggestResponse = try? await Self.apiRequest(
            "api/search/suggest/web", params: params, type: SuggestResponse.self) else { return [] }
        var out: [String] = []
        func push(_ v: String?) {
            guard let v0 = v?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v0.isEmpty, !out.contains(v0), out.count < 8 else { return }
            out.append(v0)
        }
        for a in resp.result?.artists ?? [] { push(a.name) }
        for song in resp.result?.songs ?? [] {
            push(song.artists?.first?.name)
            push(song.name)
        }
        return out
    }

    /// 用搜索建议接口纠正关键词：优先取歌手建议名（playboicarti → Playboi Carti）。
    /// 仅当纠正词与原词**只在空格/大小写上不同**（或原词完全无结果）时才采用，
    /// 避免把正常关键词替换成撞词结果。
    private func correctedMVKeyword(for keyword: String) async -> String? {
        let params: [String: Any] = ["s": keyword, "limit": 8]
        guard let resp: SuggestResponse = try? await Self.apiRequest(
            "api/search/suggest/web", params: params, type: SuggestResponse.self) else { return nil }
        let artistName = resp.result?.artists?.first?.name
        let songArtistName = resp.result?.songs?.first?.artists?.first?.name
        let candidate = (artistName?.isEmpty == false ? artistName : songArtistName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else { return nil }
        let a = keyword.replacingOccurrences(of: " ", with: "").lowercased()
        let b = candidate.replacingOccurrences(of: " ", with: "").lowercased()
        return (a == b || a.isEmpty) ? candidate : nil
    }

    private struct SuggestResponse: Decodable {
        var result: Payload?
        struct Payload: Decodable {
            var artists: [Artist]?
            var songs: [Song]?
            struct Artist: Decodable { var name: String? }
            struct Song: Decodable {
                var name: String?
                var artists: [Artist]?
            }
        }
    }

    /// 访谈 / 预告 / 花絮类 MV 标题判定（MV 搜索结果净化用）。
    private static let noisyMVKeywords: [String] = [
        "访谈", "预告", "花絮", "幕后", "采访", "彩蛋", "纪录片", "特辑",
        "片花", "未播", "先导", "直拍", "彩排", "reaction", "对话", "问候",
    ]

    private static func isNoisyMVTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return noisyMVKeywords.contains { lower.contains($0) }
    }

    /// MV 播放地址（weapi `/api/song/enhance/play/mv/url`；r = 清晰度 1080）。
    func mvURL(id: String, resolution: Int = 1080) async throws -> String? {
        let resp: MVURLResponse = try await Self.weapiRequest(
            "/api/song/enhance/play/mv/url",
            params: ["id": id, "r": resolution],
            type: MVURLResponse.self)
        return resp.data?.url
    }

    private struct MVCloudSearchResponse: Decodable {
        var result: Payload?
        struct Payload: Decodable { var mvs: [MVItem]? }
        struct MVItem: Decodable {
            var id: Int?
            var name: String?
            var cover: String?
            var artistName: String?
            var duration: Int?
            var playCount: Int?
        }
    }

    private struct MVURLResponse: Decodable {
        var data: Payload?
        struct Payload: Decodable { var url: String? }
    }

    /// 我的云盘歌曲列表（weapi `/api/v1/cloud/get`）。
    ///
    /// ⚠️ 真实响应结构（2026-10-15 实测）：`data[]` 条目里
    /// **没有 `song` 字段**，完整曲目在 `simpleSong`；未匹配到曲库的上传歌只有
    /// 条目级扁平字段 `songId / songName / artist`，或整包嵌在 `privateCloud` 里。
    /// **播放 id 一律取条目自己的 `songId`**（lx 音源与官方通道都用它当 songmid）——
    /// 早先只认 `simpleSong.id`，未匹配上传歌该字段为 0，条目能显示但解析不到
    /// 播放地址，表现为「云盘歌曲不能播放」。
    func userCloud(limit: Int = 100, offset: Int = 0) async throws -> [MusicItem] {
        let params: [String: Any] = ["limit": limit, "offset": offset]
        let resp: CloudListResponse = try await Self.weapiRequest(
            "/api/v1/cloud/get", params: params, type: CloudListResponse.self)
        return (resp.data ?? []).compactMap { entry in
            let song = entry.simpleSong
            let nested = entry.privateCloud
            let name = song?.name ?? entry.songName ?? nested?.song ?? ""
            guard !name.isEmpty else { return nil }
            // id：条目级 songId 优先，其次 privateCloud.songId，最后 simpleSong.id；
            // 全缺或为 0 的条目解析不出播放地址，直接丢弃（不留「能看点不了」的行）。
            let rawId = entry.songId ?? nested?.songId ?? song?.id ?? 0
            guard rawId > 0 else { return nil }
            let songArtist = song?.ar?.compactMap { $0.name }.joined(separator: "/")
            let artist: String
            if let songArtist, !songArtist.isEmpty {
                artist = songArtist
            } else if let entryArtist = entry.artist, !entryArtist.isEmpty {
                artist = entryArtist
            } else if let nestedArtist = nested?.artist, !nestedArtist.isEmpty {
                artist = nestedArtist
            } else {
                artist = "未知歌手"
            }
            return MusicItem(
                source: .netease,
                title: name,
                artist: artist,
                album: song?.al?.name,
                albumCoverURL: Self.neteaseCover(song?.al?.picUrl, size: 500),
                duration: TimeInterval(song?.dt ?? 0) / 1000,
                isVip: (song?.fee ?? 0) == 1 || (song?.fee ?? 0) == 4,
                neteaseId: "\(rawId)",
                platformAlbumId: song?.al?.id.map { "\($0)" },
                // ★ 2026-10-15 用户：云盘歌曲播放必须直走网易云官方通道（不走 LX），
                //   解析器靠这个标记识别（见 MusicURLResolver 的云盘分支）。
                isCloudDisk: true
            )
        }
    }

    private struct CloudListResponse: Decodable {
        var code: Int?
        var count: Int?
        var data: [Entry]?

        private enum CodingKeys: String, CodingKey {
            case code, count, data
        }

        /// 自定义解码：`count` 等配额字段可能是数字也可能是数字字符串
        /// （字面量类型不稳定会让**整条响应**解码失败 → 列表凭空消失）。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try? c.decode(Int.self, forKey: .code)
            count = (try? c.decode(Int.self, forKey: .count))
                ?? (try? c.decode(String.self, forKey: .count)).flatMap(Int.init)
            data = try? c.decode([Entry].self, forKey: .data)
        }

        struct Entry: Decodable {
            var songId: Int?
            var songName: String?
            var artist: String?
            var simpleSong: Song?
            var privateCloud: PrivateCloud?

            /// 未匹配曲库的上传歌：歌曲信息整包嵌在这里（`song` 是**字符串**歌名）。
            struct PrivateCloud: Decodable {
                var songId: Int?
                var song: String?
                var artist: String?
            }
        }
    }

    /// 我喜欢的音乐：红心 id 列表（weapi `/api/song/like/get`）
    /// + 分块详情（weapi `/api/v3/song/detail`）。
    func likedSongs(uid: String, limit: Int = 2000) async throws -> [MusicItem] {
        let resp: LikelistResponse = try await Self.weapiRequest(
            "/api/song/like/get", params: ["uid": uid], type: LikelistResponse.self)
        let ids = (resp.ids ?? []).prefix(limit).map(String.init)
        guard !ids.isEmpty else { return [] }
        var out: [MusicItem] = []
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 500, ids.count)])
            if let songs = try? await songDetails(ids: chunk) {
                out.append(contentsOf: songs)
            }
            index += 500
        }
        return out
    }

    /// 「我喜欢的音乐」歌单的封面（网易云老规矩：该歌单 id == 用户 uid）。
    /// 只取歌单元数据，不拉曲目 —— 给「我喜欢」页头部用。
    func likedPlaylistCover(uid: String) async throws -> String? {
        let idValue: Any = Int(uid).map { $0 as Any } ?? uid
        let params: [String: Any] = ["id": idValue, "n": 1, "s": 0, "csrf_token": ""]
        let resp: PlaylistDetailResponse = try await Self.apiRequest(
            "api/v6/playlist/detail", params: params, type: PlaylistDetailResponse.self)
        return resp.playlist?.coverImgUrl
    }

    /// 「我喜欢的音乐」**第一首歌曲**的专辑封面（用户 2026-10-16 问题7：
    /// 发现页「我喜欢的音乐」卡封面要按网易云我喜欢第一首歌的封面拉取）。
    ///
    /// 通道与 `likedPlaylistCover` 相同（`api/v6/playlist/detail`，`n=1`），
    /// 三级兜底（2026-10-16 问题1：用户报「还是没封面」——
    /// 原实现只认内嵌 `tracks[0]`，内嵌为空就整条返回 nil，
    /// 调用方再回落到一个**已失效的硬编码封面 URL**，于是一片空白）：
    ///   ① 内嵌 `playlist.tracks[0].al.picUrl`（最省一次请求）；
    ///   ② 内嵌空 → 用 `trackIds[0]` 走 song/detail 拿专辑封面；
    ///   ③ 再不行 → 歌单自己的 `coverImgUrl`；都没有 → nil
    ///      （调用方此时应回落渐变底，而不是去加载死链）。
    func likedFirstTrackCover(uid: String) async throws -> String? {
        let idValue: Any = Int(uid).map { $0 as Any } ?? uid
        let params: [String: Any] = ["id": idValue, "n": 1, "s": 0, "csrf_token": ""]
        let resp: PlaylistDetailResponse = try await Self.apiRequest(
            "api/v6/playlist/detail", params: params, type: PlaylistDetailResponse.self)
        if let first = resp.playlist?.tracks?.first?.al?.picUrl, !first.isEmpty {
            return first
        }
        // 内嵌 tracks 为空（大歌单服务端不内嵌，只给 trackIds）：用首项补一次歌曲详情。
        // 2026-10-16 问题1：原实现只走 `songDetails`（weapi 优先）——部分登录态下 weapi
        // 会被风控拒掉，整级失败后落到第③级「歌单默认灰心图」，用户看起来就是「没封面」。
        // 这里补一条与 `playlistForImport` 补齐路径同款的**明文 v3** 通道（真机已验证可用）。
        if let firstId = resp.playlist?.trackIds?.first?.id {
            if let songs = try? await songDetails(ids: ["\(firstId)"]),
               let cover = songs.first?.albumCoverURL, !cover.isEmpty {
                return cover
            }
            if let detail: SongsDetailResponse = try? await Self.apiRequest(
                "api/v3/song/detail",
                params: ["c": "[{\"id\":\(firstId)}]", "csrf_token": ""],
                type: SongsDetailResponse.self),
               let pic = detail.songs?.first?.effectiveAlbum?.picUrl, !pic.isEmpty {
                return pic
            }
        }
        return resp.playlist?.coverImgUrl
    }

    /// 歌曲详情（weapi `/api/v3/song/detail`，`c` 形如 `[{"id":1},{"id":2}]`）。
    /// weapi 通道失败时回退明文 `api/song/detail`（`ids=[1,2,3]`），保证总能拉到。
    func songDetails(ids: [String]) async throws -> [MusicItem] {
        guard !ids.isEmpty else { return [] }
        let cPayload = "[" + ids.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
        if let resp: SongsDetailResponse = try? await Self.weapiRequest(
            "/api/v3/song/detail", params: ["c": cPayload, "csrf_token": ""],
            type: SongsDetailResponse.self),
           let songs = resp.songs, !songs.isEmpty {
            return songs.compactMap(Self.mapSong)
        }
        // 兜底：明文通道（ids 形如 [1,2,3]）
        var comps = URLComponents(string: "https://music.163.com/api/song/detail")!
        comps.queryItems = [
            URLQueryItem(name: "ids", value: "[\(ids.joined(separator: ","))]"),
            URLQueryItem(name: "csrf_token", value: ""),
        ]
        let data = try await rawGet(comps.url!.absoluteString)
        let resp = try JSONDecoder().decode(SongsDetailResponse.self, from: data)
        return (resp.songs ?? []).compactMap(Self.mapSong)
    }

    private struct LikelistResponse: Decodable {
        var ids: [Int]?
    }

    /// 红心 / 取消红心一首歌（同步网易云「我喜欢的音乐」）。
    ///
    /// 通道：weapi `/api/radio/like`（alg=itembased，与桌面客户端一致）。
    /// ⚠️ query 串拼在 path 里一起进加密体，params 里只放表单字段。
    func likeTrack(id: String, like: Bool) async throws {
        let params: [String: Any] = ["trackId": id, "like": like]
        let resp: CodeResponse = try await Self.weapiRequest(
            "/api/radio/like?alg=itembased&trackId=\(id)&time=3",
            params: params,
            type: CodeResponse.self)
        guard (resp.code ?? -1) == 200 else {
            throw NetworkClient.NetworkError.badStatus(resp.code ?? -1)
        }
    }

    private struct LoginResponse: Decodable {
        var code: Int?
        var message: String?
        var msg: String?
        var cookie: String?
        var profile: Profile?

        struct Profile: Decodable {
            var userId: Int?
            var nickname: String?
            var avatarUrl: String?
            /// 会员类型：0 = 未开通，10 = 音乐包，11 = 黑胶VIP。
            /// ⚠️ 网易云官方明示 SVIP「网页端暂不支持展示」，web 接口不区分 SVIP；
            /// 这里对 0/10/11 之外的取值一律按 SVIP 档处理（见 NeteaseAccountCard.vipBadge）。
            var vipType: Int?
        }
    }

    private struct AccountResponse: Decodable {
        var code: Int?
        /// 未登录时是 `null`
        var profile: LoginResponse.Profile?
    }

    // MARK: 搜索（cloudsearch，按类型）

    /// 网易云搜索类型：1 单曲 / 10 专辑 / 100 歌手 / 1000 歌单
    enum SearchKind: Int {
        case songs = 1
        case albums = 10
        case artists = 100
        case playlists = 1000
    }

    func search(_ keyword: String, kind: SearchKind, limit: Int = 30) async throws -> WellSearchResult {
        try await search(keyword, kind: kind, limit: limit, page: 1).0
    }

    /// 分页搜索，并返回是否还有更多（对齐 RN 版 `hasMore` 语义）。
    ///
    /// RN 版对纯小写英文查询会额外用「首字母大写」再搜一次并合并 —— 网易云对
    /// 小写英文召回较差。这里保留该兜底，仅在首页生效。
    func search(_ keyword: String, kind: SearchKind, limit: Int = 30, page: Int) async throws -> (WellSearchResult, Bool) {
        let offset = (page - 1) * limit
        var resp = try await runSearch(keyword, kind: kind, limit: limit, offset: offset)

        // 首页 + 纯小写英文：用首字母大写补搜并合并（去重）
        let normalized = Self.normalizedQuery(keyword)
        if page == 1, normalized != keyword, kind == .songs {
            if let secondary = try? await runSearch(normalized, kind: kind, limit: limit, offset: 0),
               secondary.code == 200 {
                resp = Self.mergeSongs(primary: resp, secondary: secondary)
            }
        }
        guard resp.code == 200 else { throw NetworkClient.NetworkError.badStatus(resp.code ?? -1) }

        var out = WellSearchResult()
        var hasMore = false
        switch kind {
        case .songs:
            let songs = (resp.result?.songs ?? []).compactMap(Self.mapSong)
            out.songs = songs
            let total = resp.result?.songCount ?? resp.songCount ?? 0
            hasMore = total > 0 ? offset + songs.count < total : songs.count >= limit
        case .artists:
            let artists = resp.result?.artists ?? []
            out.artists = artists.compactMap { a in
                guard let id = a.id, let name = a.name else { return nil }
                return WellArtistSummary(
                    id: "\(id)", name: name, picURL: a.picUrl, platform: .netease,
                    mid: nil, subtitle: Self.artistSubtitle(musicSize: a.musicSize, albumSize: a.albumSize))
            }
            hasMore = artists.count >= limit
        case .albums:
            let albums = resp.result?.albums ?? []
            out.albums = albums.compactMap { al in
                guard let id = al.id, let name = al.name else { return nil }
                return WellAlbumSummary(
                    id: "\(id)", name: name, picURL: Self.neteaseCover(al.picUrl, size: 500),
                    artistName: al.artist?.name ?? "未知歌手", platform: .netease, albumMid: nil)
            }
            hasMore = albums.count >= limit
        case .playlists:
            let playlists = resp.result?.playlists ?? []
            out.playlists = playlists.compactMap { pl in
                guard let id = pl.id, let name = pl.name else { return nil }
                return WellPlaylistSummary(
                    id: "\(id)", name: name, coverURL: Self.neteaseCover(pl.coverImgUrl, size: 512),
                    playCount: Int(pl.playCount ?? 0), trackCount: pl.trackCount ?? 0,
                    creatorName: pl.creator?.nickname)
            }
            hasMore = playlists.count >= limit
        }
        return (out, hasMore)
    }

    private func runSearch(_ keyword: String, kind: SearchKind, limit: Int, offset: Int) async throws -> SearchResponse {
        // 主通道：明文 `api/cloudsearch/pc`（RN 版同款，无需加密、无需登录即可出结果）。
        // 注意走的是 `api/` 而不是 `weapi/` —— 这是搜索能出结果的关键。
        var comps = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")!
        comps.queryItems = [
            URLQueryItem(name: "s", value: keyword),
            URLQueryItem(name: "type", value: "\(kind.rawValue)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "total", value: offset == 0 ? "true" : "false"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if let url = comps.url,
           let resp = try? await NetworkClient.shared.get(url.absoluteString, headers: [
               "Referer": "https://music.163.com/",
               "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
           ]),
           let decoded = NetworkClient.decode(SearchResponse.self, from: resp.data),
           decoded.code == 200, decoded.result != nil {
            return decoded
        }

        // 没有备用通道：原先的 weapi 加密接口已被服务端停用（返回空响应体），
        // 走它只会白白多花一次请求，错误也和「什么都没拿到」一样，故直接上抛。
        throw NetworkClient.NetworkError.noData
    }

    /// 纯小写 ASCII 查询 → 每个单词首字母大写。
    private static func normalizedQuery(_ query: String) -> String {
        let isLowerASCII = query.allSatisfy { $0.isNumber || $0 == " " || ($0.isLetter && $0.isLowercase && $0.isASCII) }
        guard isLowerASCII, query.contains(where: { $0.isLetter }) else { return query }
        return query.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    /// 按歌曲 id 去重合并两次搜索结果。
    private static func mergeSongs(primary: SearchResponse, secondary: SearchResponse) -> SearchResponse {
        var merged = primary
        var songs = primary.result?.songs ?? []
        var seen = Set(songs.compactMap { $0.id })
        for song in secondary.result?.songs ?? [] {
            guard let id = song.id, !seen.contains(id) else { continue }
            seen.insert(id)
            songs.append(song)
        }
        merged.result?.songs = songs
        if let a = primary.result?.songCount, let b = secondary.result?.songCount {
            merged.result?.songCount = max(a, b)
        }
        return merged
    }

    /// 歌手专辑列表（歌手主页 / 歌手搜索详情页用）。
    ///
    /// ## 为什么必须翻页（2026-10-14 用户反馈「专辑和平台不对、少很多」）
    ///
    /// `api/artist/albums/<id>` 单页最多 50 条，且**响应里没有 total 字段** ——
    /// 旧实现只取第一页，周杰伦（44 张）刚好够，但刘德华 / 张学友这类
    /// 超过 50 张的歌手直接少一半。只能靠 `offset` 推进 + `more` 布尔判断结尾
    /// （实测：周杰伦 44 张、more=false 收尾；类型中英混合 专辑26/Single16/EP2）。
    ///
    /// - Returns: 全量专辑 + 平台侧专辑总数（`artist.albumSize`，头部统计行用；
    ///   接口没给时为 nil，调用方应回落到 `albums.count`）。
    func artistAlbums(id: String) async throws -> (albums: [WellAlbumSummary], platformAlbumCount: Int?) {
        let pageSize = 50
        // 兜底上限 20 页（1000 张）：防止接口异常（more=true 但一直返空页）导致死循环
        let maxPages = 20
        var offset = 0
        var seen = Set<Int>()
        var summaries: [WellAlbumSummary] = []
        var platformAlbumCount: Int?

        for _ in 0..<maxPages {
            let resp: ArtistAlbumsResponse = try await Self.apiRequest(
                "api/artist/albums/\(id)",
                params: ["limit": pageSize, "offset": offset, "total": true, "csrf_token": ""],
                type: ArtistAlbumsResponse.self)
            if platformAlbumCount == nil { platformAlbumCount = resp.artist?.albumSize }
            let page = resp.hotAlbums ?? []
            for al in page {
                guard let aid = al.id, let name = al.name, !seen.contains(aid) else { continue }
                seen.insert(aid)
                summaries.append(WellAlbumSummary(
                    id: "\(aid)", name: name, picURL: al.picUrl,
                    artistName: al.artist?.name ?? "未知歌手", platform: .netease, albumMid: nil,
                    albumType: al.type, publishTime: al.publishTime))
            }
            // 没有更多 或 空页（防御：more 缺失时按「页不满」推断结束）
            if !(resp.more ?? (page.count >= pageSize)) || page.isEmpty { break }
            offset += page.count
        }
        return (summaries, platformAlbumCount)
    }

    /// 兼容旧调用：仅搜索单曲
    func search(keyword: String, limit: Int = 30) async throws -> [MusicItem] {
        try await search(keyword, kind: .songs, limit: limit).songs
    }

    // MARK: 详情（点击卡片后展开歌曲列表）

    /// 歌单简介（详情页「更多」展开用；`api/v6/playlist/detail` 明文可用）。
    ///
    /// 非抛错：简介只是详情页的附加信息，网络失败时返回 nil 即可
    /// （调用方 `WellPlaylistDetailView.load()` 不接 `throws`）。
    func playlistDescription(id: String) async -> String? {
        let params: [String: Any] = ["id": id, "n": 0, "csrf_token": ""]
        guard let resp: PlaylistDetailResponse = try? await Self.apiRequest(
            "api/v6/playlist/detail", params: params, type: PlaylistDetailResponse.self
        ) else { return nil }
        return resp.playlist?.description
    }

    func playlistTracks(id: String) async throws -> [MusicItem] {
        let idValue: Any = Int(id).map { $0 as Any } ?? id
        let params: [String: Any] = ["id": idValue, "n": 100_000, "s": 8, "csrf_token": ""]
        let resp: PlaylistDetailResponse = try await Self.apiRequest(
            "api/v6/playlist/detail", params: params, type: PlaylistDetailResponse.self)
        return (resp.playlist?.tracks ?? []).compactMap(Self.mapSong)
    }

    /// 歌单导入：返回歌单名 + 封面 + **完整**歌曲列表 + 创建者昵称/头像。
    ///
    /// `api/v6/playlist/detail` 明文可用，但 `tracks` 字段在大歌单上会被服务端
    /// 截断（约前 1000 首），所以照 `trackIds` 分块走 `api/v3/song/detail`
    /// 补齐（每块 500 个 id）。
    ///
    /// ★ 2026-10-16 问题2：返回值里一并带上创建者（`creator` 字段同一个响应
    /// 里就有，不额外发请求）—— 歌单页标题下要显示创建者头像 + 昵称。
    /// 元组加字段对既有调用点（都用具名访问）源码兼容。
    func playlistForImport(id: String) async throws -> (
        name: String, coverURL: String?, tracks: [MusicItem],
        creatorName: String?, creatorAvatarURL: String?
    ) {
        let idValue: Any = Int(id).map { $0 as Any } ?? id
        let params: [String: Any] = ["id": idValue, "n": 1000, "s": 0, "csrf_token": ""]
        let resp: PlaylistDetailResponse = try await Self.apiRequest(
            "api/v6/playlist/detail", params: params, type: PlaylistDetailResponse.self)
        guard let body = resp.playlist else {
            throw NetworkClient.NetworkError.noData
        }

        var songs = body.tracks ?? []
        let allIds = (body.trackIds ?? []).compactMap { $0.id }
        if songs.count < allIds.count {
            let have = Set(songs.compactMap { $0.id })
            let missing = allIds.filter { !have.contains($0) }
            for start in stride(from: 0, to: missing.count, by: 500) {
                let end = min(start + 500, missing.count)
                let chunk = missing[start..<end]
                let cPayload = "[" + chunk.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
                if let detail: SongsDetailResponse = try? await Self.apiRequest(
                    "api/v3/song/detail", params: ["c": cPayload, "csrf_token": ""],
                    type: SongsDetailResponse.self) {
                    songs.append(contentsOf: detail.songs ?? [])
                }
            }
        }

        let tracks = songs.compactMap(Self.mapSong)
        return (body.name ?? "导入的歌单", body.coverImgUrl, tracks,
                body.creator?.nickname, body.creator?.avatarUrl)
    }

    /// 专辑歌曲
    func albumTracks(id: String) async throws -> [MusicItem] {
        let resp: AlbumDetailResponse = try await Self.apiRequest(
            "api/v1/album/\(id)", params: ["csrf_token": ""], type: AlbumDetailResponse.self)
        return (resp.songs ?? []).compactMap(Self.mapSong)
    }

    /// 歌手热门歌曲
    /// ★ 2026-10-17 歌手主页：一次拿「头像 + 热门歌曲」。
    ///   weapi v1/artist 的 artist 对象里有 picUrl/img1v1Url/cover/avatar 多套字段，
    ///   逐个兜（老接口只回其中一套）；hotSongs 为空时再走 artist/songs 兜。
    func artistProfile(id: String) async throws -> ArtistProfile {
        let resp: ArtistDetailResponse = try await Self.weapiRequest(
            "api/v1/artist/\(id)", params: ["csrf_token": ""], type: ArtistDetailResponse.self)
        // ★ 2026-10-17 用户：改为**全量歌曲**（数量与平台一致），hotSongs 兜底
        var songs = (try? await artistAllSongs(id: id)) ?? []
        if songs.isEmpty { songs = (resp.hotSongs ?? []).compactMap(Self.mapSong) }
        let artist = resp.artist
        let avatar = artist?.picUrl ?? artist?.img1v1Url ?? artist?.cover ?? artist?.avatar
        let expected = artist?.musicSize ?? artist?.songSize ?? 0
        return ArtistProfile(name: artist?.name,
                             avatarURL: (avatar?.isEmpty == false) ? avatar : nil,
                             briefDesc: artist?.briefDesc,
                             hotSongs: songs,
                             totalSongCount: expected > 0 ? expected : songs.count,
                             isFollowed: artist?.followed ?? false)
    }

    /// ★ 2026-10-17 用户：歌手页「全部歌曲」——分页把歌手歌曲**全量**拉齐
    ///   （artist_songs limit=100/页，最多 10 页 = 1000 首），数量与平台一致。
    func artistAllSongs(id: String, order: String = "hot") async throws -> [MusicItem] {
        var all: [MusicItem] = []
        var seen = Set<String>()
        // ★ 2026-10-17 修复「最多 50 首」：该接口**每页上限就是 50**（请求 100 也回 50），
        //   之前拿 100 当页大小 → 第一页就误判“不足一页”提前停。改用 50/页 +
        //   接口的 more 标志（或空页）作为停止条件，最多 20 页 = 1000 首。
        // ★ 2026-10-17 用户明确要求：**只拉 50 首**（多页串行会让首屏空等）
        let pageSize = 50
        for page in 0..<1 {
            var more: Bool?
            let batch = try await artistSongs(id: id, order: order,
                                              limit: pageSize, offset: page * pageSize,
                                              moreOut: &more)
            if batch.isEmpty { break }
            for item in batch where seen.insert(item.keyOf).inserted { all.append(item) }
            if more == false { break }
            if batch.count < pageSize { break }
        }
        return all
    }

    /// ★ 2026-10-17 相似歌手（Kumone 同款区块）：weapi /api/discovery/simiArtist
    func simiArtists(artistId: String) async throws -> [(id: String, name: String, picURL: String?)] {
        let resp: SimiArtistResponse = try await Self.weapiRequest(
            "/api/discovery/simiArtist", params: ["artistid": artistId], type: SimiArtistResponse.self)
        return (resp.artists ?? []).compactMap { a in
            guard let aid = a.id, let name = a.name, !name.isEmpty else { return nil }
            return (String(aid), name, a.picUrl ?? a.img1v1Url)
        }
    }

    private struct SimiArtistResponse: Decodable {
        var code: Int?
        var artists: [Item]?
        struct Item: Decodable {
            var id: Int64?
            var name: String?
            var picUrl: String?
            var img1v1Url: String?
        }
    }

    /// 收藏 / 取消收藏歌手（weapi /api/artist/sub|unsub）
    func setArtistSubscribed(id: String, subscribed: Bool) async throws {
        let params: [String: Any] = [
            "artistId": id,
            "artistIds": "[\\(id)]",
            "csrf_token": "",
        ]
        let path = subscribed ? "/api/artist/sub" : "/api/artist/unsub"
        let resp: CodeOnlyResponse = try await Self.weapiRequest(
            path, params: params, type: CodeOnlyResponse.self, cookieStyle: .session)
        try Self.ensureOK(resp.code, serverMessage: resp.message, fallback: "收藏歌手失败")
    }

    private struct CodeOnlyResponse: Decodable {
        var code: Int?
        var message: String?
    }

    /// 歌手歌曲（order：hot 热门序 / time 时间序）。官方增强版 artist_songs 同款参数。
    /// （moreOut：可选，带回接口的 more 标志供分页判断）
    func artistSongs(id: String, order: String = "hot", limit: Int = 50, offset: Int = 0,
                     moreOut: inout Bool?) async throws -> [MusicItem] {
        let params: [String: Any] = [
            "id": id,
            "private_cloud": "true",
            "work_type": 1,
            "order": order,
            "offset": offset,
            "limit": limit,
            "csrf_token": "",
        ]
        let resp: ArtistSongsResponse = try await Self.weapiRequest(
            "/api/v1/artist/songs", params: params, type: ArtistSongsResponse.self)
        moreOut = resp.more
        return (resp.songs ?? []).compactMap(Self.mapSong)
    }

    func artistSongs(id: String, order: String = "hot", limit: Int = 50, offset: Int = 0)
        async throws -> [MusicItem] {
        var more: Bool?
        return try await artistSongs(id: id, order: order, limit: limit, offset: offset, moreOut: &more)
    }
    private struct ArtistSongsResponse: Decodable {
        var code: Int?
        var songs: [Song]?
        var more: Bool?
    }

    func artistTopSongs(id: String) async throws -> [MusicItem] {
        // ★ 2026-10-17 用户反馈「所有歌手主页歌曲不显示」→ 明文 api/v1/artist/{id}
        //   被风控（与心动模式同款病：明文路径拿不到数据）→ 切 weapi 同路径。
        let resp: ArtistDetailResponse = try await Self.weapiRequest(
            "api/v1/artist/\(id)", params: ["csrf_token": ""], type: ArtistDetailResponse.self)
        return (resp.hotSongs ?? []).compactMap(Self.mapSong)
    }

    // MARK: 听歌排行

    /// 听歌排行单条记录
    struct PlayRecordItem {
        let song: MusicItem
        let playCount: Int
    }

    /// eapi `/api/v1/play/record` 响应：`weekData` / `allData`，每项 `song` + `playCount`。
    private struct PlayRecordEapiResponse: Decodable {
        var code: Int?
        var weekData: [Item]?
        var allData: [Item]?
        struct Item: Decodable {
            var playCount: Int?
            var score: Int?
            var song: Song?
        }
    }

    /// 听歌排行（网易云「我听过的歌」）。
    /// type: 0 = 所有时间（allData），1 = 最近一周（weekData）。
    ///
    /// 2026-10-14 用户反馈「听歌排行不显示数据」→ 根因：旧的明文 `api/user/playrecord`
    /// 登录态拿不到排行；换成参考源码 `neteaseScrobble.js` 同款的 **eapi `/api/v1/play/record`**。
    func playRecord(uid: Int, type: Int) async throws -> [PlayRecordItem] {
        let cookie = NeteaseSession.shared.cookieHeader
        // eapi 加密体内要嵌套 `header`（含 os=pc + MUSIC_U/__csrf），否则服务端静默忽略
        let params: [String: Any] = [
            "uid": String(uid),
            "type": type,
            "total": "true",
            "header": NeteaseCrypto.eapiHeaderPayload(cookie: cookie),
        ]
        let resp: PlayRecordEapiResponse = try await Self.eapiRequest(
            "/api/v1/play/record", params: params, type: PlayRecordEapiResponse.self,
            // 参考实现读排行时同样带桌面客户端 UA（Cookie 不覆写，仍是 App 自己的）。
            headers: ["User-Agent": Self.desktopClientUserAgent])
        let list = (type == 1 ? resp.weekData : resp.allData) ?? []
        return list.compactMap { item in
            guard let song = item.song, let mapped = Self.mapSong(song) else { return nil }
            return PlayRecordItem(song: mapped, playCount: item.playCount ?? 0)
        }
    }

    // MARK: 听歌上报（weblog：让网易云侧同步「听歌排行」与「最近播放」）

    /// weblog 上报的响应（`/api/feedback/weblog`）。
    private struct WeblogResp: Decodable { var code: Int? }

    /// 上报一条 weblog。eapi `/api/feedback/weblog`，与参考 `neteaseScrobble.js` 同款。
    ///
    /// 两个 action 配合：`startplay` 写入「最近播放」；`play` 累加「听歌排行」次数与时长。
    /// 无登录态时直接返回 false（不报错，静默跳过）。
    private func sendWeblog(_ logs: [[String: Any]]) async -> Bool {
        guard NeteaseSession.shared.isLoggedIn else { return false }
        let cookie = NeteaseSession.shared.cookieHeader
        let logsString = (try? JSONSerialization.data(withJSONObject: logs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let params: [String: Any] = [
            "logs": logsString,
            "header": NeteaseCrypto.eapiHeaderPayload(cookie: cookie),
        ]
        do {
            // ★ 2026-10-14：**必须**把 HTTP Cookie 换成桌面客户端特征、并带桌面 macOS UA。
            //   参考实现 `neteaseScrobble.js` 的原话：「HTTP Cookie 覆写为桌面 macOS 客户端
            //   特征 os=osx + appver=3.1.17」「否则服务端**静默忽略**」。
            //   我们此前只发了 App 自己的手机 cookie 与默认 UA —— 服务端照样回 200，
            //   但排行不涨、最近播放不同步（用户 2026-10-14 反馈的现象）。
            let resp: WeblogResp = try await Self.eapiRequest(
                "/api/feedback/weblog", params: params, type: WeblogResp.self,
                headers: [
                    "Cookie": Self.scrobbleCookie(from: cookie),
                    "User-Agent": Self.desktopClientUserAgent,
                ])
            return resp.code == 200
        } catch {
            return false
        }
    }

    /// 桌面 macOS 客户端 UA（与参考实现 `DESKTOP_UA` 一字不差）。
    private static let desktopClientUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/125.0.0.0 Safari/537.36"

    /// weblog 上报专用 Cookie 覆写：`os=osx` + `appver=3.1.17`（参考实现 `buildScrobbleCookie`）。
    private static func scrobbleCookie(from cookie: String) -> String {
        func upsert(_ source: String, key: String, value: String) -> String {
            var parts = source.split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var replaced = false
            for i in parts.indices where parts[i].lowercased().hasPrefix(key.lowercased() + "=") {
                parts[i] = "\(key)=\(value)"
                replaced = true
            }
            if !replaced { parts.append("\(key)=\(value)") }
            return parts.joined(separator: "; ")
        }
        return upsert(upsert(cookie, key: "os", value: "osx"), key: "appver", value: "3.1.17")
    }

    /// 开始播放上报（写入「最近播放」）。在歌曲开始播放时调用。
    func scrobbleStart(neteaseTrackId: String) async {
        guard let nid = Int(neteaseTrackId) else { return }
        await sendWeblog([
            ["action": "startplay", "json": [
                "id": nid, "type": "song", "mainsite": "1", "mainsiteWeb": "1",
                "content": "id=0",
            ]],
        ])
    }

    /// 播放完成 / 切歌上报（累加「听歌排行」次数与时长）。
    func scrobbleFinish(neteaseTrackId: String, seconds: Int) async {
        guard let nid = Int(neteaseTrackId), seconds > 0 else { return }
        await sendWeblog([
            ["action": "play", "json": [
                "download": 0, "end": "playend", "id": nid, "sourceId": "0",
                "time": seconds, "type": "song", "wifi": 0, "source": "list",
                "mainsite": "1", "mainsiteWeb": "1", "content": "id=0",
            ]],
        ])
    }

    /// 云端「最近播放」（`/api/play-record/song/list`，与 RN 版 v90 同款接口）。
    ///
    /// 每条记录的歌曲在 `entry.data`（标准 song 对象 ar/al/dt），另带 `playTime`；
    /// 接口按播放时间倒序返回。响应结构做了双通道兼容：
    /// `data.list`（包一层）或 `data` 直接是数组，两种都吃。
    /// 需要登录 Cookie（apiRequest 自动携带）。
    func recentSongs(limit: Int = 50) async throws -> [MusicItem] {
        struct Entry: Decodable {
            var data: Song?
            var song: Song?
            var playTime: Double?
        }
        struct ListWrapResp: Decodable {
            var code: Int?
            var data: Wrapper?
            struct Wrapper: Decodable { var list: [Entry]? }
        }
        struct ArrayResp: Decodable {
            var code: Int?
            var data: [Entry]?
        }
        let params: [String: Any] = ["limit": limit, "csrf_token": ""]

        // 通道 1：data.list 包裹结构（RN 版实测的主结构）
        if let resp: ListWrapResp = try? await Self.apiRequest(
            "api/play-record/song/list", params: params, type: ListWrapResp.self),
           let entries = resp.data?.list, !entries.isEmpty {
            return entries.compactMap { entry -> MusicItem? in
                guard let song = entry.data ?? entry.song else { return nil }
                return Self.mapSong(song)
            }
        }
        // 通道 2：data 直接是数组
        if let resp: ArrayResp = try? await Self.apiRequest(
            "api/play-record/song/list", params: params, type: ArrayResp.self),
           let entries = resp.data, !entries.isEmpty {
            return entries.compactMap { entry -> MusicItem? in
                guard let song = entry.data ?? entry.song else { return nil }
                return Self.mapSong(song)
            }
        }
        throw NetworkClient.NetworkError.noData
    }

    // MARK: 发现页（推荐歌单 / 排行榜 / 新碟上架 / 热门歌手）
    //
    // 这几个接口都**不需要登录**，所以发现页在未登录状态下也能有内容 ——
    // 这是它与「每日推荐」那类登录专属模块的关键区别。

    /// 推荐歌单（个性化推荐）
    func personalizedPlaylists(limit: Int = 30) async throws -> [WellPlaylistSummary] {
        let params: [String: Any] = ["limit": limit, "total": true, "n": 1000, "csrf_token": ""]
        let resp: PersonalizedPlaylistResponse = try await Self.apiRequest(
            "api/personalized/playlist", params: params, type: PersonalizedPlaylistResponse.self)
        return (resp.result ?? []).compactMap(Self.mapPlaylist)
    }

    /// 歌单广场：按分类拉歌单。
    ///
    /// 主通道：明文 GET `api/playlist/list?cat=...`（老接口，无需登录长期稳定）。
    /// `api/top/playlist` 在部分账号/UA 下会 301 到风控页导致解码失败，故弃用。
    func categoryPlaylists(cat: String, limit: Int = 30, offset: Int = 0) async throws -> [WellPlaylistSummary] {
        var comps = URLComponents(string: "https://music.163.com/api/playlist/list")!
        comps.queryItems = [
            URLQueryItem(name: "cat", value: cat),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "total", value: "true"),
        ]
        let data = try await rawGet(comps.url!.absoluteString)
        let resp = try JSONDecoder().decode(TopPlaylistResponse.self, from: data)
        return (resp.playlists ?? []).compactMap(Self.mapPlaylist)
    }

    /// 精品歌单（`api/playlist/highquality/list`，明文实测可用）。
    /// `before` 是上一页返回的 `lasttime`（首页传 0），用于翻页。
    func highQualityPlaylists(cat: String = "全部", limit: Int = 50, before: Int = 0)
        async throws -> (playlists: [WellPlaylistSummary], more: Bool, lasttime: Int?) {
        var comps = URLComponents(string: "https://music.163.com/api/playlist/highquality/list")!
        comps.queryItems = [
            URLQueryItem(name: "cat", value: cat),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "lasttime", value: "\(before)"),
            URLQueryItem(name: "total", value: "true"),
        ]
        let data = try await rawGet(comps.url!.absoluteString)
        let resp = try JSONDecoder().decode(HighQualityResponse.self, from: data)
        return ((resp.playlists ?? []).compactMap(Self.mapPlaylist), resp.more ?? false, resp.lasttime)
    }

    /// 相似歌曲（心动模式兜底：`api/discovery/simiSong`，明文可用）。
    func simiSongs(songId: String, limit: Int = 30) async throws -> [MusicItem] {
        let params: [String: Any] = ["songid": songId, "limit": limit, "csrf_token": ""]
        let resp: SimiSongResponse = try await Self.apiRequest(
            "api/discovery/simiSong", params: params, type: SimiSongResponse.self)
        return (resp.songs ?? []).compactMap(Self.mapSong)
    }

    /// 排行榜列表（带更新频率）
    func toplists() async throws -> [WellToplistSummary] {
        let resp: ToplistResponse = try await Self.apiRequest(
            "api/toplist", params: ["csrf_token": ""], type: ToplistResponse.self)
        return (resp.list ?? []).compactMap { item in
            guard let id = item.id else { return nil }
            return WellToplistSummary(
                id: String(id),
                name: item.name ?? "排行榜",
                coverURL: Self.neteaseCover(item.coverImgUrl, size: 500),
                updateFrequency: item.updateFrequency
            )
        }
    }

    /// 新碟上架
    func newAlbums(area: String = "ALL", limit: Int = 20) async throws -> [WellAlbumSummary] {
        let params: [String: Any] = [
            "area": area, "limit": limit, "offset": 0, "total": true, "csrf_token": "",
        ]
        let resp: NewAlbumsResponse = try await Self.apiRequest(
            "api/album/new", params: params, type: NewAlbumsResponse.self)
        return (resp.albums ?? []).compactMap(Self.mapAlbum)
    }

    /// 热门歌手
    func topArtists(limit: Int = 30) async throws -> [WellArtistSummary] {
        let params: [String: Any] = ["type": 1, "limit": limit, "offset": 0, "total": true, "csrf_token": ""]
        let resp: TopArtistsResponse = try await Self.apiRequest(
            "api/toplist/artist", params: params, type: TopArtistsResponse.self)
        return (resp.list?.artists ?? []).compactMap(Self.mapArtist)
    }

    /// 关注的歌手（需登录，`api/artist/sublist` 明文可用）
    func followedArtists(limit: Int = 30) async throws -> [WellArtistSummary] {
        let params: [String: Any] = ["limit": limit, "offset": 0, "csrf_token": ""]
        let resp: FollowedArtistsResponse = try await Self.apiRequest(
            "api/artist/sublist", params: params, type: FollowedArtistsResponse.self)
        return (resp.data ?? []).compactMap { item in
            guard let id = item.id, let name = item.name else { return nil }
            return WellArtistSummary(id: String(id), name: name, picURL: item.picUrl,
                                     platform: .netease, mid: nil, subtitle: nil)
        }
    }

    // MARK: 账号歌单 / 收藏专辑

    /// 账号歌单条目（`api/user/playlist`）。
    ///
    /// 一个账号的这份列表里混着三类：`isLoved` 的「我喜欢的音乐」、用户自建歌单、
    /// 用户收藏的别人的歌单 —— 界面上按 `isLoved` 与创建者区分。
    /// `Equatable`：`ProfileView.loadContent` 用「内容没变就不赋值」来避免货架整体重算，
    /// 靠 `fetched != neteasePlaylists` 做等值判断（Build #241 实报缺 conformance）。
    struct UserPlaylistItem: Identifiable, Equatable {
        var id: String
        var name: String
        var coverURL: String?
        var trackCount: Int
        var creatorName: String?
        /// 网易云「我喜欢的音乐」特征：`specialType == 5`。
        ///
        /// 刻意不按名字匹配 —— 用户能给这个歌单改名，名字一旦改了按名匹配就失效，
        /// 而 `specialType` 是服务端字段，改名不动它。
        var isLoved: Bool
    }

    private struct UserPlaylistsResponse: Decodable {
        var code: Int?
        var playlist: [Entry]?
        struct Entry: Decodable {
            var id: Int?
            var name: String?
            var coverImgUrl: String?
            var trackCount: Int?
            var specialType: Int?
            var creator: Creator?
            struct Creator: Decodable { var nickname: String? }
        }
    }

    /// 账号歌单列表（`api/user/playlist`，明文可用，需登录 Cookie 才会返回私人歌单）。
    ///
    /// `uid` 传 `NeteaseSession.shared.account?.userId`。
    func userPlaylists(uid: Int) async throws -> [UserPlaylistItem] {
        let params: [String: Any] = ["uid": uid, "limit": 1000, "offset": 0, "csrf_token": ""]
        let resp: UserPlaylistsResponse = try await Self.apiRequest(
            "api/user/playlist", params: params, type: UserPlaylistsResponse.self)
        return (resp.playlist ?? []).compactMap { entry in
            guard let id = entry.id else { return nil }
            return UserPlaylistItem(
                id: String(id),
                name: entry.name ?? "",
                coverURL: entry.coverImgUrl,
                trackCount: entry.trackCount ?? 0,
                creatorName: entry.creator?.nickname,
                isLoved: entry.specialType == 5
            )
        }
    }

    /// `/api/album/sublist` 响应。
    ///
    /// ⚠️ 2026-10-15 定案（接口实测）：**`data` 直接是专辑数组**
    /// （`{code, count, data: [album…]}`）。历史版本把 `data` 建模成包裹对象，
    /// 数组灌进结构体 → 整个响应解码失败 → weapi/明文/eapi 三通道**全部**倒在
    /// 解码上（表现为「修了几遍还是拿不到收藏专辑」）。现在 `data` 双形态兼容：
    /// 先按数组解，解不动再按包裹对象解；`albums` 根级字段也一并保留。
    private struct AlbumSublistResponse: Decodable {
        var code: Int?
        var count: Int?
        var albums: [Entry]?
        var data: [Entry]?

        private enum CodingKeys: String, CodingKey {
            case code, count, albums, data
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try? c.decode(Int.self, forKey: .code)
            count = (try? c.decode(Int.self, forKey: .count))
                ?? (try? c.decode(String.self, forKey: .count)).flatMap(Int.init)
            albums = try? c.decode([Entry].self, forKey: .albums)
            if let direct = try? c.decode([Entry].self, forKey: .data) {
                data = direct
            } else if let payload = try? c.decode(Payload.self, forKey: .data) {
                data = payload.albums ?? payload.list ?? payload.data
            } else {
                data = nil
            }
        }

        struct Payload: Decodable {
            var albums: [Entry]?
            var list: [Entry]?
            var data: [Entry]?
        }

        struct Entry: Decodable {
            var id: Int?
            var name: String?
            var picUrl: String?
            var size: Int?
            var publishTime: Int?
            var artist: ArtistRef?
            var artists: [ArtistRef]?
            struct ArtistRef: Decodable { var name: String? }

            private enum CodingKeys: String, CodingKey {
                case id, name, picUrl, cover, size, publishTime, artist, artists
            }

            /// 全字段容错解码：数字字段在不同账号下可能是整数/浮点/数字字符串，
            /// 任何字段的类型意外都不该让**整条响应**解码失败（云盘接口踩过同款）。
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = Self.lenientInt(c, .id)
                name = try? c.decode(String.self, forKey: .name)
                picUrl = (try? c.decode(String.self, forKey: .picUrl))
                    ?? (try? c.decode(String.self, forKey: .cover))
                size = Self.lenientInt(c, .size)
                publishTime = Self.lenientInt(c, .publishTime)
                artist = try? c.decode(ArtistRef.self, forKey: .artist)
                artists = try? c.decode([ArtistRef].self, forKey: .artists)
            }

            private static func lenientInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
                (try? c.decode(Int.self, forKey: key))
                    ?? (try? c.decode(Double.self, forKey: key)).map(Int.init)
                    ?? (try? c.decode(String.self, forKey: key)).flatMap(Int.init)
            }
        }
    }

    /// 收藏的专辑（`api/album/sublist`，需登录 Cookie）。
    ///
    /// ⚠️ 2026-10-15：真实响应是 `{code, count, data: [album…]}`（`data` 直接是数组）。
    /// 此前把 `data` 建模成包裹对象，导致**整条响应
    /// 解码失败**、三通道全空 —— 这就是「修了几遍还是拿不到」的根因。
    /// 响应结构见 `AlbumSublistResponse`（数组/包裹双形态兼容 + 字段容错）。
    ///
    /// ⚠️ 明文通道单页只稳定返回 25 条，limit 传大值会被截断 —— 内部按 25/页循环拉齐；
    /// 明文整体失败时回退 eapi 通道（登录态强绑定接口，与听歌排行同一套通道）。
    /// 最近一次「收藏专辑」拉取的通道诊断（排查用；「我的」页空态会显示）。
    nonisolated(unsafe) static var lastFavoritedAlbumsDebug = ""

    func favoritedAlbums(limit: Int = 500, offset: Int = 0) async throws -> [WellAlbumSummary] {
        var debugParts: [String] = []
        // 通道 1：weapi（登录态首选，与客户端一致）
        do {
            let albums = try await favoritedAlbumsWeapi(limit: limit, offset: offset)
            debugParts.append("weapi:" + String(albums.count))
            if !albums.isEmpty {
                Self.lastFavoritedAlbumsDebug = debugParts.joined(separator: " · ")
                return albums
            }
        } catch {
            debugParts.append("weapi:" + Self.shortDebug(error))
        }
        // 通道 2：明文分页
        do {
            let albums = try await favoritedAlbumsPlain(limit: limit, offset: offset)
            debugParts.append("plain:" + String(albums.count))
            if !albums.isEmpty {
                Self.lastFavoritedAlbumsDebug = debugParts.joined(separator: " · ")
                return albums
            }
        } catch {
            debugParts.append("plain:" + Self.shortDebug(error))
        }
        // 通道 3：eapi
        do {
            let albums = try await favoritedAlbumsEapi(limit: limit, offset: offset)
            debugParts.append("eapi:" + String(albums.count))
            Self.lastFavoritedAlbumsDebug = debugParts.joined(separator: " · ")
            return albums
        } catch {
            debugParts.append("eapi:" + Self.shortDebug(error))
            Self.lastFavoritedAlbumsDebug = debugParts.joined(separator: " · ")
            throw error
        }
    }

    /// 错误 → 短诊断串（只保留类型/状态，便于空态展示）。
    private static func shortDebug(_ error: Error) -> String {
        let text = String(describing: error)
        return String(text.prefix(60))
    }

    private func favoritedAlbumsWeapi(limit: Int, offset: Int) async throws -> [WellAlbumSummary] {
        // ⚠️ 该接口单页上限 100：直接把 500 传进去可能被服务端拒绝（返回空）。
        //    改为按 100 分页循环拼满（最多 20 页 / 2000 张，防极端值）。
        var all: [WellAlbumSummary] = []
        var current = offset
        var pages = 0
        while all.count < limit, pages < 20 {
            let pageSize = min(100, limit - all.count)
            let resp: AlbumSublistResponse = try await Self.weapiRequest(
                "/api/album/sublist",
                params: ["limit": pageSize, "offset": current, "total": true],
                type: AlbumSublistResponse.self)
            let entries = resp.albums ?? resp.data ?? []
            let page = entries.compactMap(Self.mapSublistAlbum)
            if page.isEmpty { break }
            all.append(contentsOf: page)
            current += page.count
            pages += 1
            if page.count < pageSize { break }
        }
        return all
    }

    private func favoritedAlbumsPlain(limit: Int, offset: Int) async throws -> [WellAlbumSummary] {
        var out: [WellAlbumSummary] = []
        let pageSize = 25
        var current = offset
        while out.count < limit {
            let params: [String: Any] = ["limit": pageSize, "offset": current, "total": true, "csrf_token": ""]
            let resp: AlbumSublistResponse = try await Self.apiRequest(
                "api/album/sublist", params: params, type: AlbumSublistResponse.self)
            let entries = resp.albums ?? resp.data ?? []
            if entries.isEmpty { break }
            out.append(contentsOf: entries.compactMap(Self.mapSublistAlbum))
            if entries.count < pageSize { break }
            current += pageSize
            if current >= offset + limit { break }
        }
        return Array(out.prefix(limit))
    }

    private func favoritedAlbumsEapi(limit: Int, offset: Int) async throws -> [WellAlbumSummary] {
        let params: [String: Any] = ["limit": min(limit, 100), "offset": offset, "total": true]
        let resp: AlbumSublistResponse = try await Self.eapiRequest(
            "/api/album/sublist", params: params, type: AlbumSublistResponse.self)
        let entries = resp.albums ?? resp.data ?? []
        return Array(entries.compactMap(Self.mapSublistAlbum).prefix(limit))
    }

    private static func mapSublistAlbum(_ entry: AlbumSublistResponse.Entry) -> WellAlbumSummary? {
        guard let id = entry.id else { return nil }
        let artistName = entry.artist?.name
            ?? entry.artists?.compactMap(\.name).joined(separator: " / ")
            ?? ""
        return WellAlbumSummary(
            id: String(id),
            name: entry.name ?? "",
            picURL: neteaseCover(entry.picUrl, size: 500),
            artistName: artistName,
            platform: .netease,
            albumMid: nil,
            albumType: nil,
            publishTime: entry.publishTime
        )
    }

    // MARK: 每日推荐 / 私人漫游 / 心动模式

    /// 每日推荐歌曲（发现页顶部功能卡片之一）。
    ///
    /// 实测**未登录也有内容**（服务端给一批公共推荐，34 首左右），登录后才是真正的「日推」。
    func dailyRecommendSongs() async throws -> [MusicItem] {
        let resp: DailyRecommendResponse = try await Self.apiRequest(
            "api/v3/discovery/recommend/songs", params: [:], type: DailyRecommendResponse.self)
        try Self.ensureOK(resp.code, fallback: "每日推荐加载失败")
        return (resp.data?.dailySongs ?? []).compactMap(Self.mapSong)
    }

    /// 私人漫游（私人 FM）。
    ///
    /// 服务端**每次返回 3 首**（2026-10-16 修正：旧注释「每次 1 首」是误判，
    /// 那份实测把新格式字段当空数据处理了），所以连拉几批拼成一个可播队列；
    /// 批与批之间 500ms 间隔（参考实现同款），避免被限流吞掉。
    /// 参考实现默认 3 批（9 首），首次快速开播可传 batches=1。
    func personalFMTracks(batches: Int = 3) async throws -> [MusicItem] {
        var collected: [MusicItem] = []
        var seen = Set<String>()
        for index in 0..<max(1, batches) {
            // 74 版同款：每批间隔 500ms（明文 + iPhone UA 下服务端会正常前进）
            if index > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            // ★ 2026-10-17 按 74 版参考实现对齐：漫游用**明文 api POST**
            //   `api/v1/radio/get` + **iPhone UA**（74 版实测可用；weapi 加密版反而不给）。
            let resp: FMResponse = try await Self.apiRequest(
                "api/v1/radio/get", params: [:], type: FMResponse.self,
                headers: ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"])
            try Self.ensureOK(resp.code, fallback: "私人漫游加载失败")
            for track in resp.data ?? [] {
                guard let item = Self.mapFMTrack(track) else { continue }
                guard seen.insert(item.keyOf).inserted else { continue }
                collected.append(item)
            }
        }
        // ★ 2026-10-17 兜底：节流导致只有一批（5 首）→ 用每日推荐补 10 首，
        //   保证漫游队列不会永远 5 首。
        if collected.count <= 5 {
            if let daily = try? await dailyRecommendSongs() {
                var seen = Set(collected.map { $0.keyOf })
                var added = 0
                for song in daily where added < 10 {
                    if seen.insert(song.keyOf).inserted {
                        collected.append(song); added += 1
                    }
                }
            }
        }
        return collected
    }

    /// 心动模式：以一首歌为种子、以一个歌单为口味范围，让服务端推一串相近的歌。
    ///
    /// ★ 2026-10-16 用户反馈「已登录不能播」→ 根因：原先走**明文**
    /// `api/playmode/intelligence/list`，登录态下该明文路径拿不到数据。
    /// 参考实现同款接口走 **weapi** `/api/playmode/intelligence/list`
    /// （songId / type=fromPlayOne / playlistId / startMusicId / count / csrf_token），
    /// 已切过来。种子由调用方给（参考实现用**每日推荐第一首**，见 DiscoverView）。
    func intelligenceList(songId: String, playlistId: String, count: Int = 1) async throws -> [MusicItem] {
        let params: [String: Any] = [
            "songId": songId,
            "type": "fromPlayOne",
            "playlistId": playlistId,
            "startMusicId": songId,
            "count": String(count),
            "csrf_token": "",
        ]
        // ★ 2026-10-17 按 74 版对齐：心动必须用**登录态 Cookie**（此前 device 指纹
        //   = 未登录态，数据少还易被风控）；count 用字符串 '1'（74 版同款）。
        let resp: IntelligenceResponse = try await Self.weapiRequest(
            "/api/playmode/intelligence/list", params: params,
            type: IntelligenceResponse.self, cookieStyle: .session)
        try Self.ensureOK(resp.code, serverMessage: resp.message, fallback: "心动模式加载失败")
        return (resp.data ?? []).compactMap { $0.songInfo }.compactMap(Self.mapSong)
    }

    /// ★ 2026-10-17 用户反馈「心动模式只有五首歌」→ 根因：单次调用只回 1-5 首。
    ///   官方客户端的玩法是**链式**：拿上一次推荐的最后一首当新种子继续要，
    ///   累积到目标数量为止（去重、连续两轮无新歌提前收手）。
    func intelligenceChain(songId: String, playlistId: String, target: Int = 20) async throws -> [MusicItem] {
        var collected: [MusicItem] = []
        var seen = Set<String>()
        var seed = songId
        var dryRounds = 0
        for round in 0..<10 {
            // ★ 2026-10-17：连续快速请求会被风控（第 2 轮就空 → 只剩 5 首）。
            //   每轮间隔 0.8s，单轮失败不中断已收集部分。
            if round > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            let batch = (try? await intelligenceList(songId: seed, playlistId: playlistId, count: 3)) ?? []
            let fresh = batch.filter { seen.insert($0.keyOf).inserted }
            if fresh.isEmpty {
                dryRounds += 1
                if dryRounds >= 2 { break }
            } else {
                dryRounds = 0
                collected.append(contentsOf: fresh)
                seed = fresh.last?.neteaseId ?? seed
            }
            if collected.count >= target { break }
        }
        // ★ 2026-10-17 兜底：链式被风控时（<12 首）用「相似歌曲」补足到 target，
        //   保证心动模式永远不止 5 首。
        if collected.count < 12,
           let similar = try? await simiSongs(songId: songId), !similar.isEmpty {
            var seen = Set(collected.map { $0.keyOf })
            for song in similar where collected.count < target {
                if seen.insert(song.keyOf).inserted { collected.append(song) }
            }
        }
        return collected
    }

    // MARK: - 评论详情页（★ 2026-10-17：weapi 三端点，参考 api-enhanced-main）
    //
    // comment_new（排序分页）/ comment_hot（热评）/ comment_floor（楼中楼）。
    // 歌曲资源类型 = R_SO_4。

    struct NeteaseComment: Identifiable, Hashable {
        let id: String
        let nickname: String
        let avatarURL: String?
        let content: String
        let timeText: String
        let likedCount: Int
        let replyCount: Int
    }

    private struct CommentUserDTO: Decodable {
        var nickname: String?
        var avatarUrl: String?
    }

    private struct CommentDTO: Decodable {
        var commentId: Int64?
        var content: String?
        var time: Double?
        var likedCount: Int?
        var replyCount: Int?
        var user: CommentUserDTO?
    }

    private struct CommentNewResponse: Decodable {
        var code: Int?
        var message: String?
        var data: Data?
        struct Data: Decodable {
            var comments: [CommentDTO]?
            var totalCount: Int?
            var hasMore: Bool?
        }
    }

    private struct CommentHotResponse: Decodable {
        var code: Int?
        var hotComments: [CommentDTO]?
        var total: Int?
        var more: Bool?
    }

    private struct CommentFloorResponse: Decodable {
        var code: Int?
        var message: String?
        var data: Data?
        struct Data: Decodable {
            var comments: [CommentDTO]?
            var totalCount: Int?
        }
    }

    private static let commentTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    private static func mapComment(_ c: CommentDTO) -> NeteaseComment {
        let timeMs = c.time ?? 0
        let timeText = timeMs > 0
            ? commentTimeFormatter.string(from: Date(timeIntervalSince1970: timeMs / 1000))
            : ""
        return NeteaseComment(
            id: c.commentId.map(String.init) ?? UUID().uuidString,
            nickname: c.user?.nickname ?? "网易云用户",
            avatarURL: c.user?.avatarUrl,
            content: c.content ?? "",
            timeText: timeText,
            likedCount: c.likedCount ?? 0,
            replyCount: c.replyCount ?? 0)
    }

    private static func mapComments(_ list: [CommentDTO]?) -> [NeteaseComment] {
        (list ?? []).map(mapComment)
    }

    /// 新版评论列表。sortType：99 推荐 / 2 最热 / 3 最新。
    func songComments(songId: String, sortType: Int, pageNo: Int, pageSize: Int = 20)
        async throws -> (comments: [NeteaseComment], total: Int, hasMore: Bool) {
        // ★ 2026-10-17：官方模块里 sortType 99 的 cursor 是**数字**，
        //   传字符串 "0" 服务端会返回空列表（推荐 tab 空白的根因）。
        let cursor: Any = (pageNo - 1) * pageSize
        let params: [String: Any] = [
            "threadId": "R_SO_4_\(songId)",
            "pageNo": pageNo,
            "pageSize": pageSize,
            "sortType": sortType,
            "cursor": cursor,
            "csrf_token": "",
        ]
        let resp: CommentNewResponse = try await Self.weapiRequest(
            "/api/resource/comments/R_SO_4_\(songId)", params: params, type: CommentNewResponse.self)
        try Self.ensureOK(resp.code, serverMessage: resp.message, fallback: "评论加载失败")
        let d = resp.data
        return (Self.mapComments(d?.comments), d?.totalCount ?? 0, d?.hasMore ?? false)
    }

    /// 热门评论
    func songHotComments(songId: String, offset: Int = 0, limit: Int = 20)
        async throws -> (comments: [NeteaseComment], total: Int) {
        let params: [String: Any] = [
            "rid": songId,
            "offset": offset,
            "limit": limit,
            "beforeTime": 0,
            "csrf_token": "",
        ]
        let resp: CommentHotResponse = try await Self.weapiRequest(
            "/api/v1/resource/hotcomments/R_SO_4_\(songId)", params: params, type: CommentHotResponse.self)
        try Self.ensureOK(resp.code, fallback: "热评加载失败")
        return (Self.mapComments(resp.hotComments), resp.total ?? 0)
    }

    /// 楼中楼（一条评论的回复列表）
    func songCommentFloor(songId: String, parentCommentId: String, time: Int = -1, limit: Int = 20)
        async throws -> (replies: [NeteaseComment], total: Int) {
        let params: [String: Any] = [
            "parentCommentId": parentCommentId,
            "threadId": "R_SO_4_\(songId)",
            "time": time,
            "limit": limit,
            "csrf_token": "",
        ]
        let resp: CommentFloorResponse = try await Self.weapiRequest(
            "/api/resource/comment/floor/get", params: params, type: CommentFloorResponse.self)
        try Self.ensureOK(resp.code, serverMessage: resp.message, fallback: "回复加载失败")
        let d = resp.data
        return (Self.mapComments(d?.comments), d?.totalCount ?? 0)
    }

    /// 私人 FM 的歌曲结构**两套都可能出现**：老格式（`artists` / `album` /
    /// `duration`）与新格式（`ar` / `al` / `dt`，与搜索、日推同一套）。
    /// 2026-10-16 实测当前服务端返回的是**新格式** —— 只按老格式映射会把
    /// 歌手 / 封面 / 时长全部丢掉（歌能放但信息全空），所以两套都接。
    private static func mapFMTrack(_ track: FMTrack) -> MusicItem? {
        guard let id = track.id, let name = track.name else { return nil }
        let artistNames: String? = {
            if let ar = track.ar, !ar.isEmpty {
                return ar.compactMap { $0.name }.joined(separator: "/")
            }
            return track.artists?.compactMap { $0.name }.joined(separator: "/")
        }()
        let artistText = artistNames.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手"
        return MusicItem(
            source: .netease,
            title: name,
            artist: artistText,
            album: track.al?.name ?? track.album?.name,
            albumCoverURL: track.al?.picUrl ?? track.album?.picUrl,
            duration: TimeInterval(track.dt ?? track.duration ?? 0) / 1000,
            neteaseId: "\(id)"
        )
    }

    // MARK: 登录
    //
    // 三种方式共用同一套票据逻辑：登录成功后服务端会把 `MUSIC_U`（有时还带 `__csrf`）
    // 通过 **`Set-Cookie` 响应头**下发，`apiRequest` 已经统一吸收进 `NeteaseSession`；
    // 少数响应还会在 body 里再给一份 `cookie` 字段，这里也一并接住。
    //
    // ⚠️ 密码登录要传 **MD5 之后**的密码，不是明文 —— 网易云的约定。

    /// 二维码扫码状态。
    enum NeteaseQRState: Equatable {
        /// 801：等待扫码
        case waiting
        /// 802：已扫码，等手机上点确认
        case scanned(nickname: String?)
        /// 800：二维码失效，需要刷新
        case expired
        /// 803：确认成功，票据已到手
        case confirmed
    }

    /// 二维码内容。网易云 App 扫到它会跳到授权页。
    static func qrLoginURL(unikey: String) -> String {
        "https://music.163.com/login?codekey=\(unikey)"
    }

    /// 申请一个二维码 unikey。
    ///
    /// 走 weapi，参数与 Cookie 与参考实现**逐字节一致**：`["type": 1]`，
    /// Cookie 只发会话票据 + `os=pc` / `appver=3.1.17`（见 `WeapiCookieStyle.session`）。
    /// `csrf_token` 由 `weapiRequest` 按会话里的 `__csrf` 自动填入。
    ///
    /// ⚠️ 2026-10-16 改动：这里原本会先 `resetQRLoginSession()` 清掉 NMTID / `__csrf`
    /// 再申请。实测参考实现**不做任何重置**，而清掉 NMTID 反而让「申请二维码」与
    /// 「轮询」两次请求的设备特征对不上，手机端确认后票据不落回来 —— 已移除该重置。
    func qrLoginKey() async throws -> String {
        let resp: QRKeyResponse = try await Self.weapiRequest(
            "/api/login/qrcode/unikey", params: ["type": 1],
            type: QRKeyResponse.self, cookieStyle: .session)
        try Self.ensureOK(resp.code, fallback: "二维码获取失败")
        guard let key = resp.unikey, !key.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        return key
    }

    /// 轮询二维码状态（参考实现 1.2s 一次）。
    ///
    /// 走 weapi：`key` / `type` 两个参数，与参考实现一致（`csrf_token` 由
    /// `weapiRequest` 自动补会话里的值）。少了 payload 里的 csrf，
    /// 手机确认后服务端会一直回 802。
    func qrLoginCheck(key: String) async throws -> NeteaseQRState {
        let resp: QRPollResponse = try await Self.weapiRequest(
            "/api/login/qrcode/client/login",
            params: ["key": key, "type": 1],
            type: QRPollResponse.self, cookieStyle: .session)
        // 803 时票据可能只在响应体的 cookie 字段里，Set-Cookie 已由 weapiRequest 吸收
        if let cookie = resp.cookie, !cookie.isEmpty {
            NeteaseSession.shared.ingest(cookieString: cookie)
        }
        switch resp.code ?? 0 {
        case 803: return .confirmed
        case 802: return .scanned(nickname: resp.nickname)
        case 801: return .waiting
        case 800: return .expired
        default:
            throw NeteaseAPIError(code: resp.code ?? -1,
                                  message: resp.message ?? "二维码登录失败")
        }
    }

    /// 发送登录用短信验证码。
    ///
    /// 走 weapi，参数与参考实现一致：`ctcode` / `cellphone` / `secrete`；
    /// `csrf_token` 不再手工写死空串，交给 `weapiRequest` 按会话里的 `__csrf` 补
    /// （参考实现就是这样，会话里没有才是空串）。
    func sendLoginSMSCode(phone: String, countryCode: String = "86") async throws {
        let resp: CodeResponse = try await Self.weapiRequest(
            "/api/sms/captcha/sent",
            params: ["cellphone": phone, "ctcode": countryCode,
                     "secrete": "music_middleuser_pclogin"],
            type: CodeResponse.self, cookieStyle: .session)
        try Self.ensureOK(resp.code, serverMessage: resp.message ?? resp.msg, fallback: "验证码发送失败")
    }

    /// 手机号登录：验证码与密码二选一。
    ///
    /// 走 weapi（对齐参考实现）：`weapi/w/login/cellphone`，参数
    /// `type` / `https` / `phone` / `countrycode` / `captcha` / `remember` / `secureCaptcha`
    /// 一一对应。登录成功的票据（`MUSIC_U` 等）走 `Set-Cookie` 下发，
    /// 由 `weapiRequest` 自动吸收；个别情况下响应体也会给一份 `cookie` 字段，一并接住。
    @discardableResult
    func loginCellphone(phone: String,
                        captcha: String? = nil,
                        password: String? = nil,
                        countryCode: String = "86") async throws -> NeteaseAccount {
        var params: [String: Any] = [
            "type": "1", "https": "true",
            "phone": phone, "countrycode": countryCode,
            "remember": "true", "secureCaptcha": "",
        ]
        if let captcha, !captcha.isEmpty { params["captcha"] = captcha }
        // 约定：服务端要的是 MD5
        if let password, !password.isEmpty { params["password"] = CryptoUtils.md5(password) }

        let resp: LoginResponse = try await Self.weapiRequest(
            "/api/w/login/cellphone", params: params,
            type: LoginResponse.self, cookieStyle: .session)
        if let cookie = resp.cookie, !cookie.isEmpty {
            NeteaseSession.shared.ingest(cookieString: cookie)
        }
        try Self.ensureOK(resp.code, serverMessage: resp.message ?? resp.msg, fallback: "登录失败")

        // 有些账号模式下服务端只回票据、不回资料，这里以「有没有票据」为准，
        // 资料再补拉一次。
        if let profile = resp.profile, let account = Self.mapAccount(profile) {
            return account
        }
        guard NeteaseSession.shared.isLoggedIn else {
            throw NeteaseAPIError(code: -1, message: "登录没有返回票据，请改用扫码或 Cookie 方式")
        }
        return try await userAccount()
    }

    /// 当前账号资料。未登录时服务端返回 `profile: null` —— 这也是校验票据是否还有效的手段。
    ///
    /// 优先明文 **GET** `api/nuser/account/get`（参考实现同款，实测匿名状态下与
    /// POST 路径行为一致）；GET 拿不到再回退旧的 POST `api/w/nuser/account/get`。
    func userAccount() async throws -> NeteaseAccount {
        if let account = try? await Self.getAccountViaGet() {
            return account
        }
        let resp: AccountResponse = try await Self.apiRequest(
            "api/w/nuser/account/get", params: [:], type: AccountResponse.self)
        guard let profile = resp.profile, let account = Self.mapAccount(profile) else {
            throw NeteaseAPIError(code: resp.code ?? 301, message: "登录已过期，请重新登录")
        }
        return account
    }

    /// GET `api/nuser/account/get`（无 `/w/` 前缀，参考实现同款）。
    private static func getAccountViaGet() async throws -> NeteaseAccount {
        let data = try await NetworkClient.shared.get(
            "https://music.163.com/api/nuser/account/get",
            headers: [
                "Referer": "https://music.163.com/",
                "Cookie": NeteaseSession.shared.cookieHeader,
            ]
        ).data
        guard let resp = NetworkClient.decode(AccountResponse.self, from: data),
              let profile = resp.profile, let account = mapAccount(profile) else {
            throw NeteaseAPIError(code: 301, message: "登录已过期，请重新登录")
        }
        return account
    }

    /// 退出登录（失败也不抛：本地票据无论如何都要清掉）。
    func logout() async {
        let _: CodeResponse? = try? await Self.apiRequest(
            "api/logout", params: ["csrf_token": NeteaseSession.shared.cookie(named: "__csrf") ?? ""],
            type: CodeResponse.self)
    }

    private static func mapAccount(_ profile: LoginResponse.Profile) -> NeteaseAccount? {
        guard let id = profile.userId else { return nil }
        return NeteaseAccount(
            userId: id,
            nickname: profile.nickname ?? "网易云用户",
            avatarURL: profile.avatarUrl,
            vipType: profile.vipType
        )
    }

    /// 业务码非 200 → 抛成人话。带上服务端原话，方便用户截图后直接定位。
    private static func ensureOK(_ code: Int?, serverMessage: String? = nil, fallback: String) throws {
        guard let code else { return }
        guard code == 200 else {
            throw NeteaseAPIError(
                code: code,
                message: NeteaseAPIError.describe(code, serverMessage: serverMessage, fallback: fallback)
            )
        }
    }

    // MARK: 播放地址（音质：standard/higher/exhigh/lossless/hires）

    /// 官方播放地址（登录态；云盘歌曲与「内置音源」兜底走这里）。
    ///
    /// ★ 2026-10-16 用户反馈「云盘还是不能播放」→ 补齐三条通道 / 一处降级：
    ///   * 云盘上传歌的 id 只在账号云盘里有效，公共曲库的 `player/url/v1` 对它回空；
    ///   * **云盘文件没有档位概念**，按「无损 / Hi-Res」去要一定回 `url: null`；
    ///   * 登录态下 eapi 通道（加密体内带客户端 header）比明文 / weapi 稳。
    /// 顺序（都带登录 Cookie）：
    ///   ① 云盘曲目：老端点 `player/url`（按 `br` 取）→ eapi `player/url/v1`
    ///      → `download/url/v1`（云盘文件直链）
    ///   ② 全部曲目：明文 `player/url/v1` → weapi `player/url/v1` → eapi `player/url/v1`（兜底）
    /// 每一步在**档位降级链**上最多试两档（用户档位 → standard，见
    /// `WellAudioQuality.neteaseLevelLadder`）。普通曲目的通道顺序保持原样不变，
    /// eapi 只作为最后一档兜底。
    /// 风控响应（`code:-462`，滑块验证）单独识别：换网络 / 稍后再试，
    /// 不再和「没有返回数据」混在一起看不清真因。
    func resolvePlayURL(item: MusicItem, quality: WellAudioQuality) async throws -> String {
        guard let id = item.neteaseId ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        let idValue: Any = Int(id).map { $0 as Any } ?? id
        let idString = "[\(id)]"
        var riskMessage: String?

        /// 从响应里取地址（数组 / 单对象两种形态都接住）。
        func extractURL(from resp: URLResponse) -> String? {
            (resp.data?.items?.first?.url ?? resp.data?.single?.url).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// eapi `player/url/v1`（加密体内必须带客户端 header，否则服务端静默忽略）。
        func eapiPlayerURL(level: String) async -> URLResponse? {
            let params: [String: Any] = [
                "ids": idString,
                "level": level,
                "encodeType": "flac",
                "header": NeteaseCrypto.eapiHeaderPayload(cookie: NeteaseSession.shared.cookieHeader),
            ]
            return try? await Self.eapiRequest("/api/song/enhance/player/url/v1",
                                               params: params, type: URLResponse.self)
        }

        /// 明文 `player/url/v1`。
        func plainPlayerURL(level: String) async -> URLResponse? {
            try? await Self.apiRequest("api/song/enhance/player/url/v1",
                                       params: ["ids": idString, "level": level,
                                                "encodeType": "flac", "csrf_token": ""],
                                       type: URLResponse.self)
        }

        // ① 云盘曲目：先走「按码率」的老端点 —— 云盘文件不带档位信息，命中率最高。
        // ★ 2026-10-16 问题7：weapi（带设备指纹）优先 —— 云盘 id 是账号私有资源、
        //   风控重点；裸明文会话 Cookie 被风控时服务端回 200 + url:null（不报错），
        //   表面看就是「没数据」，三条通道全空后只剩一句 noData。weapi 失败再退明文。
        if item.isCloudDisk {
            for br in quality.neteaseBitrateLadder {
                if let resp: URLResponse = try? await Self.weapiRequest(
                    "/api/song/enhance/player/url",
                    params: ["id": idValue, "ids": idString, "br": br],
                    type: URLResponse.self) {
                    if resp.isRiskControl {
                        riskMessage = resp.message
                    } else if let address = extractURL(from: resp) {
                        return address
                    }
                }
                if let resp: URLResponse = try? await Self.apiRequest(
                    "api/song/enhance/player/url",
                    params: ["id": idValue, "ids": idString, "br": br, "csrf_token": ""],
                    type: URLResponse.self) {
                    if resp.isRiskControl {
                        riskMessage = resp.message
                    } else if let address = extractURL(from: resp) {
                        return address
                    }
                }
            }
        }

        // ② 云盘曲目：eapi 通道 + 档位降级（云盘上传文件在 standard 档一定有地址）
        if item.isCloudDisk {
            for level in quality.neteaseLevelLadder {
                guard let resp = await eapiPlayerURL(level: level) else { continue }
                if resp.isRiskControl {
                    riskMessage = resp.message
                } else if let address = extractURL(from: resp) {
                    return address
                }
            }
        }

        // ③ 云盘曲目：文件直链端点（`data` 为单对象）
        if item.isCloudDisk {
            for level in quality.neteaseLevelLadder {
                if let resp: URLResponse = try? await Self.apiRequest(
                    "api/song/enhance/download/url/v1",
                    params: ["id": idValue, "level": level,
                             "encodeType": "flac", "csrf_token": ""],
                    type: URLResponse.self) {
                    if resp.isRiskControl {
                        riskMessage = resp.message
                    } else if let address = extractURL(from: resp) {
                        return address
                    }
                }
            }
        }

        // ④ 明文播放端点（普通曲目从这里开始，顺序与原实现一致）
        for level in quality.neteaseLevelLadder {
            guard let resp = await plainPlayerURL(level: level) else { continue }
            if resp.isRiskControl {
                riskMessage = resp.message
            } else if let address = extractURL(from: resp) {
                return address
            }
        }

        // ⑤ weapi 播放端点（带设备指纹 Cookie，风控评分低于裸明文）
        for level in quality.neteaseLevelLadder {
            if let resp: URLResponse = try? await Self.weapiRequest(
                "/api/song/enhance/player/url/v1",
                params: ["ids": idString, "level": level, "encodeType": "flac"],
                type: URLResponse.self) {
                if resp.isRiskControl {
                    riskMessage = resp.message
                } else if let address = extractURL(from: resp) {
                    return address
                }
            }
        }

        // ⑥ eapi 播放端点（最后一档兜底：登录态下这条最不容易被风控吃掉）
        for level in quality.neteaseLevelLadder {
            guard let resp = await eapiPlayerURL(level: level) else { continue }
            if resp.isRiskControl {
                riskMessage = resp.message
            } else if let address = extractURL(from: resp) {
                return address
            }
        }

        if let riskMessage {
            throw NetworkClient.NetworkError.riskControl(riskMessage)
        }
        throw NetworkClient.NetworkError.noData
    }

    // MARK: 纯文本接口（搜索等不需要加密的备用通道，保留给歌词/评论）

    func rawGet(_ url: String) async throws -> Data {
        try await NetworkClient.shared.get(url, headers: ["Referer": "https://music.163.com/"]).data
    }

    // MARK: 映射助手

    private static func mapSong(_ song: Song) -> MusicItem? {
        guard let id = song.id, let name = song.name else { return nil }
        let artistNames = song.effectiveArtists?.compactMap { $0.name }.joined(separator: "/")
        return MusicItem(
            source: .netease,
            title: name,
            artist: artistNames?.isEmpty == false ? artistNames : "未知歌手",
            album: song.effectiveAlbum?.name,
            albumCoverURL: neteaseCover(song.effectiveAlbum?.picUrl, size: 500),
            duration: TimeInterval(song.dt ?? 0) / 1000,
            isVip: (song.fee ?? 0) == 1 || (song.fee ?? 0) == 4,
            neteaseId: "\(id)",
            platformAlbumId: song.effectiveAlbum?.id.map { "\($0)" },
            neteaseMvId: (song.mv ?? 0) > 0 ? "\(song.mv!)" : nil
        )
    }

    /// 从网易云歌单移除歌曲（weapi `/api/playlist/manipulate/tracks`，op=del）。
    /// ★ 2026-10-16 用户：自动导入的网易云歌单，移除要云端同步。
    func removeTracks(fromPlaylist pid: String, trackIds: [Int]) async -> Bool {
        guard !pid.isEmpty, !trackIds.isEmpty else { return false }
        let idsJson = "[" + trackIds.map(String.init).joined(separator: ",") + "]"
        let params: [String: Any] = [
            "op": "del",
            "pid": pid,
            "trackIds": idsJson,
            "tracks": idsJson,
        ]
        let resp = try? await Self.weapiRequest("/api/playlist/manipulate/tracks",
                                                params: params,
                                                type: ManipulateResult.self)
        return resp?.code == 200
    }

    private struct ManipulateResult: Decodable { var code: Int? }

    private static func artistSubtitle(musicSize: Int?, albumSize: Int?) -> String? {
        // ★ 2026-10-16 第十一轮问题9（用户追加）：热门歌手卡副标题整体移除
        //   （「N 首单曲」「N 张专辑」都不要）
        return nil
    }

    // MARK: 映射助手（发现页）

    private static func mapPlaylist(_ item: PlaylistItem) -> WellPlaylistSummary? {
        guard let id = item.id else { return nil }
        return WellPlaylistSummary(
            id: String(id),
            name: item.name ?? "歌单",
            // 个性化推荐只给 picUrl，搜索/歌单接口给 coverImgUrl —— 两个都接住。
            // 封面统一重取大尺寸（原始 URL 常带 thumbnail=140y140 小图参数）。
            coverURL: neteaseCover(item.coverImgUrl ?? item.picUrl, size: 512),
            playCount: Int(item.playCount ?? 0),
            trackCount: item.trackCount ?? 0,
            creatorName: item.creator?.nickname
        )
    }

    private static func mapAlbum(_ item: AlbumItem) -> WellAlbumSummary? {
        guard let id = item.id else { return nil }
        return WellAlbumSummary(
            id: String(id),
            name: item.name ?? "专辑",
            picURL: neteaseCover(item.picUrl, size: 500),
            artistName: item.artist?.name ?? "未知歌手",
            platform: .netease,
            albumMid: nil
        )
    }

    private static func mapArtist(_ item: ArtistItem) -> WellArtistSummary? {
        guard let id = item.id else { return nil }
        return WellArtistSummary(
            id: String(id),
            name: item.name ?? "歌手",
            picURL: item.picUrl,
            platform: .netease,
            mid: nil,
            subtitle: artistSubtitle(musicSize: item.musicSize, albumSize: item.albumSize)
        )
    }
}

/// 网易云**业务层**错误：HTTP 是 200，但响应体里的 `code` 不是 200。
///
/// 和 `NetworkClient.NetworkError`（传输层失败：断网、超时、5xx）分开 ——
/// 登录这类流程里「手机号或密码不正确」是正常业务结果，不该被当成网络故障，
/// 文案也要能直接显示给用户看。
struct NeteaseAPIError: LocalizedError {
    let code: Int
    let message: String

    var errorDescription: String? { message }

    /// 把裸错误码翻成人话。只挑登录链路上真会碰到的几个，其余带原始码方便排查。
    static func describe(_ code: Int, serverMessage: String? = nil, fallback: String) -> String {
        switch code {
        case 301: return "登录已过期，请重新登录"
        case 400: return "手机号格式不正确"
        case 501: return "账号不存在"
        case 502: return "手机号或密码不正确"
        case 503: return "操作过于频繁，请稍后再试"
        case 505: return "该账号被风控限制，请稍后再试"
        case 509: return "登录过于频繁，请 24 小时后再试"
        case 800: return "二维码已失效，请刷新"
        case 801: return "尚未扫码"
        case 802: return "已扫码，请在手机上确认"
        case 803: return "登录成功"
        case 8821: return "该账号仅支持手机号登录"
        default:
            // 服务端自己的话最准（如「验证码错误」「操作过于频繁」），优先用它
            return "\(serverMessage?.isEmpty == false ? serverMessage! : fallback)（错误码 \(code)）"
        }
    }
}