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

    func search(keyword: String, platform: WellSearchPlatform, type: WellSearchType) async -> WellSearchResult {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return WellSearchResult() }

        switch type {
        case .all: return await searchAll(key, platform: platform)
        case .songs: return await songs(key, platform: platform, limit: 50)
        case .artists: return await artists(key, platform: platform, limit: 50)
        case .albums: return await albums(key, platform: platform, limit: 50)
        case .playlists: return await playlists(key, platform: platform, limit: 50)
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

    private func songs(_ key: String, platform: WellSearchPlatform, limit: Int) async -> WellSearchResult {
        var out = WellSearchResult()
        do {
            switch platform {
            case .netease:
                out.songs = try await NeteaseMusicAPI.shared.search(key, kind: .songs, limit: limit).songs
            case .qq:
                out.songs = try await QQMusicAPI.shared.search(keyword: key, limit: limit)
            case .kugou:
                out.songs = try await KugouMusicAPI.shared.search(keyword: key, limit: limit)
            }
        } catch { }
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

    private func playlists(_ key: String, platform: WellSearchPlatform, limit: Int) async -> WellSearchResult {
        var out = WellSearchResult()
        guard platform == .netease else { return out }
        do {
            out.playlists = try await NeteaseMusicAPI.shared.search(key, kind: .playlists, limit: limit).playlists
        } catch { }
        return out
    }

    // MARK: 卡片详情

    /// 展开歌手 / 专辑 / 歌单卡片对应的歌曲列表。
    func detailTracks(for source: WellSearchDetailSource) async -> [MusicItem] {
        switch source {
        case .playlist(let id, let platform, _):
            guard platform == .netease else { return [] }
            return (try? await NeteaseMusicAPI.shared.playlistTracks(id: id)) ?? []
        case .album(let id, let platform, let name, let artist):
            if platform == .netease {
                return (try? await NeteaseMusicAPI.shared.albumTracks(id: id)) ?? []
            }
            return await fallbackSearchTracks("\(name) \(artist)", platform: platform)
        case .artist(let id, let platform, let name):
            if platform == .netease {
                let tracks = (try? await NeteaseMusicAPI.shared.artistTopSongs(id: id)) ?? []
                if !tracks.isEmpty { return tracks }
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
}