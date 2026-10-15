import Foundation

/// 网易云音乐 API。
///
/// ⚠️ **通道说明（2026-10 实测，改动前务必先读这段）**
///
/// `music.163.com/weapi/*`（AES + RSA 加密通道）**已被服务端停用**：
/// 不论参数是否正确，一律返回 `HTTP 200 + 空响应体（0 字节）`。
/// 已实测：两个域名（`music.163.com` / `interface.music.163.com`）、
/// 带不带 Cookie 都一样 —— 也就是说这条通道上的调用会**静默拿不到任何数据**，
/// 而不是抛出一个明确的错误。
///
/// 明文 `api/*` 通道**全部正常**（搜索页一直能出结果就是因为它走的是明文，
/// 见 `runSearch` 里的注释）。所以本文件统一走明文通道：`apiRequest(_:params:type:)`。
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
    /// 之所以不用 `NeteaseCrypto.weapi`：加密通道已被服务端停用，只会返回空响应体，
    /// 详见本文件头部说明。
    private static func apiRequest<T: Decodable>(_ path: String,
                                                 params: [String: Any] = [:],
                                                 type: T.Type) async throws -> T {
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
            headers: [
                "Referer": "https://music.163.com/",
                "Origin": "https://music.163.com",
                // 登录后所有请求都要带票据，否则拿到的是匿名数据
                // （发现页 / 每日推荐 / 我喜欢 这类会直接空手而归）。
                "Cookie": NeteaseSession.shared.cookieHeader,
            ]
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

    /// weapi POST（`https://music.163.com/weapi/…`）。
    ///
    /// - path 一律以 `/api/` 开头：内部去掉 `/api` 前缀拼到 `/weapi` 之后（与客户端一致）。
    /// - 加密：`NeteaseWeapi.weapi`（AES-CBC 双层 + **密钥反转后的无填充 RSA**）。
    /// - Cookie = 设备指纹（首次自动生成并持久化）+ 登录票据；payload 的 `csrf_token`
    ///   与 Cookie 里的 `__csrf` 保持一致。
    private static func weapiRequest<T: Decodable>(_ path: String,
                                                   params: [String: Any],
                                                   type: T.Type) async throws -> T {
        let suffix = path.hasPrefix("/api") ? String(path.dropFirst(4)) : path
        var payload = params
        if payload["csrf_token"] == nil {
            payload["csrf_token"] = NeteaseSession.shared.cookie(named: "__csrf") ?? ""
        }
        let enc = NeteaseWeapi.weapi(payload)
        guard let paramsValue = enc["params"], !paramsValue.isEmpty,
              let encSecKey = enc["encSecKey"], !encSecKey.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        let form = "params=\(escapeForm(paramsValue))&encSecKey=\(escapeForm(encSecKey))"
        let resp = try await NetworkClient.shared.postRaw(
            "https://music.163.com/weapi\(suffix)",
            body: Data(form.utf8),
            contentType: "application/x-www-form-urlencoded",
            headers: [
                "Referer": "https://music.163.com/",
                "Origin": "https://music.163.com",
                "Cookie": neteaseWebCookieHeader(),
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
            "NMTID=\(randomHex(length: 16))",
        ]
        let sessionCookie = NeteaseSession.shared.cookieHeader
        if !sessionCookie.isEmpty { parts.append(sessionCookie) }
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
        var ar: [Artist]?
        var al: Album?
        var dt: Int?
        /// 网易云付费标记：1 = VIP 歌曲、4 = 购买专辑、8 = 低音质免费。仅用于列表行 VIP 徽章。
        var fee: Int?
        struct Artist: Decodable { var name: String? }
        struct Album: Decodable {
            var id: Int?
            var name: String?
            var picUrl: String?
        }
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
            struct TrackID: Decodable { var id: Int? }
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
    }

    private struct URLResponse: Decodable {
        var code: Int?
        var data: [URLItem]?
        struct URLItem: Decodable {
            var url: String?
            var br: Int?
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

    /// 私人 FM 的歌曲（老格式，与 `Song` 不同，见 `mapFMTrack` 的说明）
    private struct FMTrack: Decodable {
        var id: Int?
        var name: String?
        /// 毫秒
        var duration: Int?
        var artists: [Artist]?
        var album: Album?
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
    func searchMVs(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [WellMVSummary] {
        let params: [String: Any] = ["s": keyword, "type": 1004,
                                     "limit": limit, "offset": offset, "total": true]
        let resp: MVCloudSearchResponse = try await Self.apiRequest(
            "api/cloudsearch/pc", params: params, type: MVCloudSearchResponse.self)
        return (resp.result?.mvs ?? []).compactMap { mv in
            guard let id = mv.id else { return nil }
            return WellMVSummary(
                id: "\(id)",
                name: mv.name ?? "",
                coverURL: neteaseCover(mv.cover, size: 500),
                artistName: mv.artistName,
                duration: TimeInterval(mv.duration ?? 0) / 1000,
                playCount: mv.playCount ?? 0,
                platform: .netease)
        }
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

    /// 我喜欢的音乐（Kumone 同款链路）：红心 id 列表（weapi `song/like/get`）
    /// + 分块详情（明文 `api/song/detail`）。
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

    /// 歌曲详情（明文 `api/song/detail`，`ids` 形如 `[1,2,3]`）。
    func songDetails(ids: [String]) async throws -> [MusicItem] {
        guard !ids.isEmpty else { return [] }
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

    /// 歌单导入：返回歌单名 + 封面 + **完整**歌曲列表。
    ///
    /// `api/v6/playlist/detail` 明文可用，但 `tracks` 字段在大歌单上会被服务端
    /// 截断（约前 1000 首），所以照 `trackIds` 分块走 `api/v3/song/detail`
    /// 补齐（每块 500 个 id）。
    func playlistForImport(id: String) async throws -> (name: String, coverURL: String?, tracks: [MusicItem]) {
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
        return (body.name ?? "导入的歌单", body.coverImgUrl, tracks)
    }

    /// 专辑歌曲
    func albumTracks(id: String) async throws -> [MusicItem] {
        let resp: AlbumDetailResponse = try await Self.apiRequest(
            "api/v1/album/\(id)", params: ["csrf_token": ""], type: AlbumDetailResponse.self)
        return (resp.songs ?? []).compactMap(Self.mapSong)
    }

    /// 歌手热门歌曲
    func artistTopSongs(id: String) async throws -> [MusicItem] {
        let resp: ArtistDetailResponse = try await Self.apiRequest(
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
    struct UserPlaylistItem: Identifiable {
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

    private struct AlbumSublistResponse: Decodable {
        var code: Int?
        var albums: [Entry]?
        var data: Payload?
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
        }
    }

    /// 收藏的专辑（`api/album/sublist`，需登录 Cookie）。
    ///
    /// ⚠️ 这个接口的 payload 层级在不同账号下不一致：有时 `albums` 直接挂在根上，
    /// 有时藏在 `data.albums` / `data.list` / `data.data` 里。四个位置都试一遍 ——
    /// 只认一个位置的话，换个账号就整页空白（与 `recentSongs` 的双通道兜底同理）。
    ///
    /// ⚠️ 明文通道单页只稳定返回 25 条，limit 传大值会被截断 —— 内部按 25/页循环拉齐；
    /// 明文整体失败时回退 eapi 通道（登录态强绑定接口，与听歌排行同一套通道）。
    func favoritedAlbums(limit: Int = 500, offset: Int = 0) async throws -> [WellAlbumSummary] {
        // 通道 1：weapi（登录态首选，与客户端一致）
        if let albums = try? await favoritedAlbumsWeapi(limit: limit, offset: offset), !albums.isEmpty {
            return albums
        }
        // 通道 2：明文分页
        if let albums = try? await favoritedAlbumsPlain(limit: limit, offset: offset), !albums.isEmpty {
            return albums
        }
        // 通道 3：eapi
        return try await favoritedAlbumsEapi(limit: limit, offset: offset)
    }

    private func favoritedAlbumsWeapi(limit: Int, offset: Int) async throws -> [WellAlbumSummary] {
        let resp: AlbumSublistResponse = try await Self.weapiRequest(
            "/api/album/sublist",
            params: ["limit": limit, "offset": offset, "total": true],
            type: AlbumSublistResponse.self)
        let entries = resp.albums ?? resp.data?.albums ?? resp.data?.list ?? resp.data?.data ?? []
        return entries.compactMap(Self.mapSublistAlbum)
    }

    private func favoritedAlbumsPlain(limit: Int, offset: Int) async throws -> [WellAlbumSummary] {
        var out: [WellAlbumSummary] = []
        let pageSize = 25
        var current = offset
        while out.count < limit {
            let params: [String: Any] = ["limit": pageSize, "offset": current, "total": true, "csrf_token": ""]
            let resp: AlbumSublistResponse = try await Self.apiRequest(
                "api/album/sublist", params: params, type: AlbumSublistResponse.self)
            let entries = resp.albums ?? resp.data?.albums ?? resp.data?.list ?? resp.data?.data ?? []
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
        let entries = resp.albums ?? resp.data?.albums ?? resp.data?.list ?? resp.data?.data ?? []
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
    /// 服务端**每次只返回 1 首**（实测），所以这里连拉几批拼成一个可播队列；
    /// 批与批之间留一点间隔，避免被限流吞掉。
    func personalFMTracks(batches: Int = 4) async throws -> [MusicItem] {
        var collected: [MusicItem] = []
        var seen = Set<String>()
        for index in 0..<max(1, batches) {
            if index > 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
            let resp: FMResponse = try await Self.apiRequest(
                "api/v1/radio/get", params: [:], type: FMResponse.self)
            try Self.ensureOK(resp.code, fallback: "私人漫游加载失败")
            for track in resp.data ?? [] {
                guard let item = Self.mapFMTrack(track) else { continue }
                guard seen.insert(item.keyOf).inserted else { continue }
                collected.append(item)
            }
        }
        return collected
    }

    /// 心动模式：以一首歌为种子、以一个歌单为口味范围，让服务端推一串相近的歌。
    func intelligenceList(songId: String, playlistId: String) async throws -> [MusicItem] {
        let params: [String: Any] = [
            "songId": songId,
            "type": "fromPlayOne",
            "playlistId": playlistId,
            "startMusicId": songId,
            "count": 1,
            "csrf_token": "",
        ]
        let resp: IntelligenceResponse = try await Self.apiRequest(
            "api/playmode/intelligence/list", params: params, type: IntelligenceResponse.self)
        try Self.ensureOK(resp.code, serverMessage: resp.message, fallback: "心动模式加载失败")
        return (resp.data ?? []).compactMap { $0.songInfo }.compactMap(Self.mapSong)
    }

    /// 私人 FM 的歌曲结构是**老格式**（`artists` / `album` / `duration`），
    /// 与搜索、日推用的 `ar` / `al` / `dt` 不是一套 —— 实测确认，别混用。
    private static func mapFMTrack(_ track: FMTrack) -> MusicItem? {
        guard let id = track.id, let name = track.name else { return nil }
        let names = track.artists?.compactMap { $0.name }.joined(separator: "/")
        return MusicItem(
            source: .netease,
            title: name,
            artist: names?.isEmpty == false ? names : "未知歌手",
            album: track.album?.name,
            albumCoverURL: track.album?.picUrl,
            duration: TimeInterval(track.duration ?? 0) / 1000,
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
    func qrLoginKey() async throws -> String {
        let resp: QRKeyResponse = try await Self.apiRequest(
            "api/login/qrcode/unikey", params: ["type": 1], type: QRKeyResponse.self)
        try Self.ensureOK(resp.code, fallback: "二维码获取失败")
        guard let key = resp.unikey, !key.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        return key
    }

    /// 轮询二维码状态（建议 1.5s 一次）。
    func qrLoginCheck(key: String) async throws -> NeteaseQRState {
        let resp: QRPollResponse = try await Self.apiRequest(
            "api/login/qrcode/client/login", params: ["key": key, "type": 1],
            type: QRPollResponse.self)
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
    func sendLoginSMSCode(phone: String, countryCode: String = "86") async throws {
        let resp: CodeResponse = try await Self.apiRequest(
            "api/sms/captcha/sent",
            params: ["cellphone": phone, "ctcode": countryCode,
                     "secrete": "music_middleuser_pclogin", "csrf_token": ""],
            type: CodeResponse.self)
        try Self.ensureOK(resp.code, serverMessage: resp.message ?? resp.msg, fallback: "验证码发送失败")
    }

    /// 手机号登录：验证码与密码二选一。
    @discardableResult
    func loginCellphone(phone: String,
                        captcha: String? = nil,
                        password: String? = nil,
                        countryCode: String = "86") async throws -> NeteaseAccount {
        var params: [String: Any] = [
            "type": "1", "https": "true",
            "phone": phone, "countrycode": countryCode,
            "remember": "true", "secureCaptcha": "", "csrf_token": "",
        ]
        if let captcha, !captcha.isEmpty { params["captcha"] = captcha }
        // 约定：服务端要的是 MD5
        if let password, !password.isEmpty { params["password"] = CryptoUtils.md5(password) }

        let resp: LoginResponse = try await Self.apiRequest(
            "api/w/login/cellphone", params: params, type: LoginResponse.self)
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
    func userAccount() async throws -> NeteaseAccount {
        let resp: AccountResponse = try await Self.apiRequest(
            "api/w/nuser/account/get", params: [:], type: AccountResponse.self)
        guard let profile = resp.profile, let account = Self.mapAccount(profile) else {
            throw NeteaseAPIError(code: resp.code ?? 301, message: "登录已过期，请重新登录")
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
            avatarURL: profile.avatarUrl
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

    func resolvePlayURL(item: MusicItem, quality: WellAudioQuality) async throws -> String {
        guard let id = item.neteaseId ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        let params: [String: Any] = [
            "ids": "[\(id)]",
            "level": quality.neteaseLevel,
            "encodeType": "flac",
            "csrf_token": "",
        ]
        let resp: URLResponse = try await Self.apiRequest(
            "api/song/enhance/player/url/v1", params: params, type: URLResponse.self)
        guard let url = resp.data?.first?.url, !url.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        return url
    }

    // MARK: 纯文本接口（搜索等不需要加密的备用通道，保留给歌词/评论）

    func rawGet(_ url: String) async throws -> Data {
        try await NetworkClient.shared.get(url, headers: ["Referer": "https://music.163.com/"]).data
    }

    // MARK: 映射助手

    private static func mapSong(_ song: Song) -> MusicItem? {
        guard let id = song.id, let name = song.name else { return nil }
        let artistNames = song.ar?.compactMap { $0.name }.joined(separator: "/")
        return MusicItem(
            source: .netease,
            title: name,
            artist: artistNames?.isEmpty == false ? artistNames : "未知歌手",
            album: song.al?.name,
            albumCoverURL: neteaseCover(song.al?.picUrl, size: 500),
            duration: TimeInterval(song.dt ?? 0) / 1000,
            isVip: (song.fee ?? 0) == 1 || (song.fee ?? 0) == 4,
            neteaseId: "\(id)",
            platformAlbumId: song.al?.id.map { "\($0)" }
        )
    }

    private static func artistSubtitle(musicSize: Int?, albumSize: Int?) -> String? {
        guard let musicSize, musicSize > 0 else { return nil }
        if let albumSize, albumSize > 0 { return "\(musicSize) 首单曲 · \(albumSize) 张专辑" }
        return "\(musicSize) 首单曲"
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