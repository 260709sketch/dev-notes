import Foundation

/// 网易云音乐 API（weapi 加密版）
final class NeteaseMusicAPI {
    static let shared = NeteaseMusicAPI()

    init() {}

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
        var coverImgUrl: String?
        var playCount: Int?
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
                    playCount: pl.playCount ?? 0, trackCount: pl.trackCount ?? 0,
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

        // 备用通道：原 weapi 加密接口（主通道异常时兜底）
        let params: [String: Any] = [
            "s": keyword,
            "type": kind.rawValue,
            "offset": offset,
            "limit": limit,
            "total": offset == 0,
            "csrf_token": "",
        ]
        return try await NeteaseCrypto.weapi(
            "weapi/cloudsearch/get/web", params: params, type: SearchResponse.self)
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
        let resp: ArtistAlbumsResponse = try await NeteaseCrypto.weapi(
            "weapi/artist/albums/\(id)", params: ["limit": limit, "offset": 0, "total": true, "csrf_token": ""],
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
        let resp: PlaylistDetailResponse = try await NeteaseCrypto.weapi(
            "weapi/v6/playlist/detail", params: params, type: PlaylistDetailResponse.self)
        return (resp.playlist?.tracks ?? []).compactMap(Self.mapSong)
    }

    /// 专辑歌曲
    func albumTracks(id: String) async throws -> [MusicItem] {
        let resp: AlbumDetailResponse = try await NeteaseCrypto.weapi(
            "weapi/v1/album/\(id)", params: ["csrf_token": ""], type: AlbumDetailResponse.self)
        return (resp.songs ?? []).compactMap(Self.mapSong)
    }

    /// 歌手热门歌曲
    func artistTopSongs(id: String) async throws -> [MusicItem] {
        let resp: ArtistDetailResponse = try await NeteaseCrypto.weapi(
            "weapi/v1/artist/\(id)", params: ["csrf_token": ""], type: ArtistDetailResponse.self)
        return (resp.hotSongs ?? []).compactMap(Self.mapSong)
    }

    // MARK: 播放地址（weapi 音质：standard/higher/exhigh/lossless/hires）

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
        let resp: URLResponse = try await NeteaseCrypto.weapi(
            "weapi/song/enhance/player/url/v1", params: params, type: URLResponse.self)
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
}