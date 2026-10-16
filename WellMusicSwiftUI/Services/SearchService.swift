import Foundation

/// 搜索聚合服务：按「平台 + 模块」拉取结果，并按需展开卡片详情。
@MainActor
final class SearchService {
    static let shared = SearchService()
    private init() {}

    /// 综合页各分类的取样数量
    private enum Sample {
        static let songs = 12
        static let others = 10
    }

    // MARK: 搜索

    /// - Parameter limit: 单类结果的拉取上限（综合页取样用小值，单曲页全量用大值）
    func search(keyword: String, platform: WellSearchPlatform, type: WellSearchType, limit: Int = 50) async -> WellSearchResult {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return WellSearchResult() }

        switch type {
        case .all: return await searchAll(key, platform: platform)
        case .songs: return await songs(key, platform: platform, limit: limit)
        case .artists: return await artists(key, platform: platform, limit: limit)
        case .albums: return await albums(key, platform: platform, limit: limit)
        case .playlists: return await playlists(key, platform: platform, limit: limit)
        case .mvs: return await mvs(key, platform: platform, limit: limit)
        }
    }

    private func searchAll(_ key: String, platform: WellSearchPlatform) async -> WellSearchResult {
        async let songsTask = songs(key, platform: platform, limit: Sample.songs)
        async let artistsTask = artists(key, platform: platform, limit: Sample.others)
        async let albumsTask = albums(key, platform: platform, limit: Sample.others)
        async let playlistsTask = playlists(key, platform: platform, limit: Sample.others)

        var out = WellSearchResult()
        let (s, ar, al, pl) = await (songsTask, artistsTask, albumsTask, playlistsTask)
        out.songs = s.songs
        out.artists = ar.artists
        out.albums = al.albums
        out.playlists = pl.playlists
        return out
    }

    /// 单曲分页（搜索页「加载更多」用）。
    /// hasMore 判定：网易云用接口总数；QQ 单页上限 30（接口硬限制）；酷狗按返回满页判。
    func songsPage(_ key: String, platform: WellSearchPlatform, limit: Int, page: Int) async -> (songs: [MusicItem], hasMore: Bool) {
        switch platform {
        case .netease:
            if let (r, hasMore) = try? await NeteaseMusicAPI.shared.search(key, kind: .songs, limit: limit, page: page) {
                return (r.songs, hasMore)
            }
        case .qq:
            if let list = try? await QQMusicAPI.shared.search(keyword: key, limit: limit, page: page) {
                // ⚠️ 不能用固定 30 判「还有更多」：分页 limit 是 10 时永远判不出，
                //    表现为「只有十几首、下滑不刷新」（QQ 单页上限 30，取 min 兼容）。
                return (list, list.count >= min(limit, 30))
            }
        case .kugou:
            if let list = try? await KugouMusicAPI.shared.search(keyword: key, limit: limit, page: page) {
                return (list, list.count >= limit)
            }
        }
        return ([], false)
    }

    private func songs(_ key: String, platform: WellSearchPlatform, limit: Int) async -> WellSearchResult {
        var out = WellSearchResult()
        out.songs = await songsPage(key, platform: platform, limit: limit, page: 1).songs
        return out
    }

    private func artists(_ key: String, platform: WellSearchPlatform, limit: Int) async -> WellSearchResult {
        var out = WellSearchResult()
        do {
            switch platform {
            case .netease:
                out.artists = try await NeteaseMusicAPI.shared.search(key, kind: .artists, limit: limit).artists
            case .qq:
                out.artists = try await QQMusicAPI.shared.searchArtists(keyword: key, limit: limit)
            case .kugou:
                out.artists = try await KugouMusicAPI.shared.searchArtists(keyword: key, limit: limit)
            }
        } catch { }
        return out
    }

    private func albums(_ key: String, platform: WellSearchPlatform, limit: Int) async -> WellSearchResult {
        var out = WellSearchResult()
        do {
            switch platform {
            case .netease:
                out.albums = try await NeteaseMusicAPI.shared.search(key, kind: .albums, limit: limit).albums
            case .qq:
                out.albums = try await QQMusicAPI.shared.searchAlbums(keyword: key, limit: limit)
            case .kugou:
                out.albums = try await KugouMusicAPI.shared.searchAlbums(keyword: key, limit: limit)
            }
        } catch { }
        return out
    }

    /// MV 搜索（当前仅网易通道提供关键词搜索；其余平台返回空）。
    private func mvs(_ key: String, platform: WellSearchPlatform, limit: Int) async -> WellSearchResult {
        var out = WellSearchResult()
        guard platform == .netease else { return out }
        out.mvs = (try? await NeteaseMusicAPI.shared.searchMVs(keyword: key, limit: limit)) ?? []
        return out
    }

    private func playlists(_ key: String, platform: WellSearchPlatform, limit: Int) async -> WellSearchResult {
        var out = WellSearchResult()
        do {
            switch platform {
            case .netease:
                out.playlists = try await NeteaseMusicAPI.shared.search(key, kind: .playlists, limit: limit).playlists
            case .qq:
                out.playlists = try await QQMusicAPI.shared.searchPlaylists(keyword: key, limit: limit)
            case .kugou:
                out.playlists = try await KugouMusicAPI.shared.searchPlaylists(keyword: key, limit: limit)
            }
        } catch { }
        return out
    }

    // MARK: 卡片详情

    /// 展开歌手 / 专辑 / 歌单卡片对应的歌曲列表。
    /// 优先走各平台的真实详情接口；失败时再退回同名搜索兜底。
    func detailTracks(for source: WellSearchDetailSource) async -> [MusicItem] {
        switch source {
        case .tracks(let items, _):
            return items

        case .playlist(let id, let platform, let name):
            // ★ 2026-10-16 用户问题18：「搜索页的 QQ 音乐歌单搜索」——
            //   搜索页能搜出 QQ / 酷狗歌单卡片，但原先点进去只有网易云有内容
            //   （`guard platform == .netease else { return [] }`），
            //   观感就是「QQ 歌单搜得到、点不开」。现在接上各平台自己的歌单详情接口。
            switch platform {
            case .netease:
                return (try? await NeteaseMusicAPI.shared.playlistTracks(id: id)) ?? []
            case .qq:
                if let detail = try? await QQMusicAPI.shared.playlistDetail(dissTid: id),
                   !detail.tracks.isEmpty {
                    return detail.tracks
                }
            case .kugou:
                if let tracks = try? await KugouMusicAPI.shared.playlistSongs(specialId: id),
                   !tracks.isEmpty {
                    return tracks
                }
            default:
                break
            }
            // 平台详情接口拿不到时退回同名搜索（不混平台）
            return await fallbackSearchTracks(name, platform: platform)

        case .album(let id, let platform, let name, let artist, let mid):
            switch platform {
            case .netease:
                let tracks = (try? await NeteaseMusicAPI.shared.albumTracks(id: id)) ?? []
                if !tracks.isEmpty { return tracks }
            case .qq:
                // QQ 专辑详情接口要的是 **albummid**（字母串）；
                // 传数字 id 会拿不到数据，然后掉进「按专辑名搜歌」的兜底 ——
                // 展示的就不是这张专辑的歌了（用户实测反馈）。
                let albumMid = mid ?? id
                let tracks = (try? await QQMusicAPI.shared.albumSongs(albumMid: albumMid)) ?? []
                if !tracks.isEmpty { return tracks }
            case .kugou:
                // 酷狗专辑：真实专辑歌曲接口
                if let detail = try? await KugouMusicAPI.shared.albumDetail(albumId: mid ?? id),
                   !detail.songs.isEmpty {
                    return detail.songs
                }
            default:
                break
            }
            // ★ 2026-10-16 用户问题19：「播放器里播 QQ 音乐 / 酷狗的歌，进专辑页面
            //   会有该歌手其他专辑混入」—— 根因就是下面这句兜底：真实专辑接口拿不到
            //   数据时用「专辑名 + 歌手名」去**搜索**，返回的是该歌手的搜索命中，
            //   自然夹着其它专辑的歌。现在对兜底结果按**专辑名归一化比对**过滤，
            //   只保留本专辑的曲目；过滤后为空就给空态（宁可空，也不混入别的专辑）。
            let fallback = await fallbackSearchTracks("\(name) \(artist)", platform: platform)
            let wanted = Self.normalizedAlbumName(name)
            guard !wanted.isEmpty else { return fallback }
            return fallback.filter { Self.normalizedAlbumName($0.album ?? "") == wanted }

        case .artist(let id, let platform, let name, let mid):
            switch platform {
            case .netease:
                let tracks = (try? await NeteaseMusicAPI.shared.artistTopSongs(id: id)) ?? []
                if !tracks.isEmpty { return tracks }
            case .qq:
                // QQ 歌手歌曲要的是 **singermid**（字母串），不是数字歌手 id
                let singerMid = mid ?? id
                let result = try? await QQMusicAPI.shared.singerSongs(singerMid: singerMid, begin: 0, num: 50)
                if let list = result?.list, !list.isEmpty { return list }
            case .kugou:
                // 酷狗歌手歌曲
                if let detail = try? await KugouMusicAPI.shared.singerDetail(singerId: mid ?? id),
                   !detail.songs.isEmpty {
                    return detail.songs
                }
            default:
                break
            }
            return await fallbackSearchTracks(name, platform: platform)
        }
    }

    /// QQ / 酷狗暂无独立详情接口，用同名搜索兜底
    private func fallbackSearchTracks(_ keyword: String, platform: MusicSource) async -> [MusicItem] {
        do {
            switch platform {
            case .qq: return try await QQMusicAPI.shared.search(keyword: keyword, limit: 50)
            case .kugou: return try await KugouMusicAPI.shared.search(keyword: keyword, limit: 50)
            case .netease: return try await NeteaseMusicAPI.shared.search(keyword: keyword, limit: 50)
            default: return []
            }
        } catch {
            return []
        }
    }

    /// 专辑名归一化：小写、剔除括号补充说明与常见分隔符，用于兜底结果比对。
    ///
    /// 例：《叶惠美》→ 叶惠美；`叶惠美 (Deluxe Edition)` → 叶惠美。
    static func normalizedAlbumName(_ text: String) -> String {
        var value = text.lowercased()
        for pair in [("（", "）"), ("(", ")"), ("[", "]")] {
            while let start = value.range(of: pair.0),
                  let end = value.range(of: pair.1, range: start.upperBound..<value.endIndex) {
                value.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        for character in ["《", "》", " ", "\t", "\n", "-", "–", "—", "·", ":", "：", "\""] {
            value = value.replacingOccurrences(of: character, with: "")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}