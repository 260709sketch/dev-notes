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
        let body = Data(formEncode(params).utf8)
        let resp = try await NetworkClient.shared.postRaw(
            "https://music.163.com/\(path)",
            body: body,
            contentType: "application/x-www-form-urlencoded",
            headers: ["Referer": "https://music.163.com/", "Origin": "https://music.163.com"]
        )
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
        struct Artist: Decodable { var name: String? }
        struct Album: Decodable {
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
    }

    private struct PlaylistDetailResponse: Decodable {
        var code: Int?
        var playlist: Body?
        struct Body: Decodable { var tracks: [Song]? }
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
                    id: "\(id)", name: name, picURL: al.picUrl,
                    artistName: al.artist?.name ?? "未知歌手", platform: .netease, albumMid: nil)
            }
            hasMore = albums.count >= limit
        case .playlists:
            let playlists = resp.result?.playlists ?? []
            out.playlists = playlists.compactMap { pl in
                guard let id = pl.id, let name = pl.name else { return nil }
                return WellPlaylistSummary(
                    id: "\(id)", name: name, coverURL: pl.coverImgUrl,
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

    /// 歌手专辑列表（歌手详情页用）。
    func artistAlbums(id: String, limit: Int = 50) async throws -> [WellAlbumSummary] {
        let resp: ArtistAlbumsResponse = try await Self.apiRequest(
            "api/artist/albums/\(id)", params: ["limit": limit, "offset": 0, "total": true, "csrf_token": ""],
            type: ArtistAlbumsResponse.self)
        return (resp.hotAlbums ?? []).compactMap { al in
            guard let id = al.id, let name = al.name else { return nil }
            return WellAlbumSummary(
                id: "\(id)", name: name, picURL: al.picUrl,
                artistName: al.artist?.name ?? "未知歌手", platform: .netease, albumMid: nil)
        }
    }

    /// 兼容旧调用：仅搜索单曲
    func search(keyword: String, limit: Int = 30) async throws -> [MusicItem] {
        try await search(keyword, kind: .songs, limit: limit).songs
    }

    // MARK: 详情（点击卡片后展开歌曲列表）

    /// 歌单歌曲
    func playlistTracks(id: String) async throws -> [MusicItem] {
        let idValue: Any = Int(id).map { $0 as Any } ?? id
        let params: [String: Any] = ["id": idValue, "n": 100_000, "s": 8, "csrf_token": ""]
        let resp: PlaylistDetailResponse = try await Self.apiRequest(
            "api/v6/playlist/detail", params: params, type: PlaylistDetailResponse.self)
        return (resp.playlist?.tracks ?? []).compactMap(Self.mapSong)
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

    /// 排行榜列表（带更新频率）
    func toplists() async throws -> [WellToplistSummary] {
        let resp: ToplistResponse = try await Self.apiRequest(
            "api/toplist", params: ["csrf_token": ""], type: ToplistResponse.self)
        return (resp.list ?? []).compactMap { item in
            guard let id = item.id else { return nil }
            return WellToplistSummary(
                id: String(id),
                name: item.name ?? "排行榜",
                coverURL: item.coverImgUrl,
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
            albumCoverURL: song.al?.picUrl,
            duration: TimeInterval(song.dt ?? 0) / 1000,
            neteaseId: "\(id)"
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
            coverURL: item.coverImgUrl ?? item.picUrl,
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
            picURL: item.picUrl,
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