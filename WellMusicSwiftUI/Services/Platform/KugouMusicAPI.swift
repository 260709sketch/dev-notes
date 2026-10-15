import Foundation

/// 酷狗音乐 API
///
/// 对齐 RN 版 v90 `helpers/userApi/kugou-music-api.js`：
/// - 搜索结果字段做了多键名兼容（不同接口返回 album_name / albumname / AlbumName 等）
/// - 封面按 `imgUrl → album_pic → cover → trans_param.union_cover → 按 albumId 拼图床` 逐级回退
/// - 歌手搜索结果会批量补全真实头像（前 10 个）
final class KugouMusicAPI {
    static let shared = KugouMusicAPI()

    init() {}

    private let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Referer": "https://www.kugou.com/",
    ]

    // MARK: - 搜索歌曲

    /// 搜索歌曲。
    ///
    /// 主通道：`songsearch.kugou.com/song_search_v2`（https 可用，需 `platform=AndroidFilter`
    /// + 桌面 Chrome UA，参考 Kumone KugouAPI.searchSongs）。
    /// 回退：`mobilecdn.kugou.com/api/v3/search/song` —— ⚠️ mobilecdn 系接口**必须用 http**，
    /// https 会返回空响应（curl 实测 + 参考源码注释双确认），这是此前酷狗搜索全挂的根因。
    func search(keyword: String, limit: Int = 30, page: Int = 1) async throws -> [MusicItem] {
        if let results = await songSearchV2(keyword, limit: limit, page: page), !results.isEmpty {
            return results
        }
        return try await mobilecdnSearch(keyword, limit: limit, page: page)
    }

    /// 主通道：song_search_v2（lx-music 同款）。
    private func songSearchV2(_ keyword: String, limit: Int, page: Int = 1) async -> [MusicItem]? {
        let url = "https://songsearch.kugou.com/song_search_v2?" +
            "platform=AndroidFilter&iscorrection=1&keyword=\(kugouEncode(keyword))&hifiquality=0" +
            "&pagesize=\(limit)&PrivilegeFilter=0&page=\(page)"
        guard let resp = try? await NetworkClient.shared.get(url, headers: [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Referer": "https://www.kugou.com/",
        ]),
              let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let lists = data["lists"] as? [[String: Any]] else {
            return nil
        }
        return lists.compactMap { parseSong($0) }
    }

    /// 备用：mobilecdn v3 接口（必须 http）。
    private func mobilecdnSearch(_ keyword: String, limit: Int, page: Int = 1) async throws -> [MusicItem] {
        let url = "http://mobilecdn.kugou.com/api/v3/search/song?" +
            "format=json&keyword=\(kugouEncode(keyword))&page=\(page)&pagesize=\(limit)" +
            "&showtype=1&plat=2&version=8990"
        let resp = try await NetworkClient.shared.get(url, headers: headers)
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            return []
        }
        return info.compactMap { parseSong($0) }
    }

    /// 统一歌曲格式化（多键名兼容 + 封面回退链）。
    /// - Parameter fallbackSinger: 专辑/歌手详情页可传入歌手名兜底。
    private func parseSong(_ dict: [String: Any], fallbackSinger: String? = nil) -> MusicItem? {
        let hash = (dict["hash"] as? String) ?? (dict["FileHash"] as? String)
            ?? (dict["file_hash"] as? String) ?? ""
        guard !hash.isEmpty else { return nil }

        let title = (dict["OriSongName"] as? String) ?? (dict["songname"] as? String)
            ?? (dict["SongName"] as? String) ?? (dict["name"] as? String)
            ?? (dict["title"] as? String) ?? Self.titleFromFilename(dict["filename"] as? String)
        let albumName = (dict["album_name"] as? String) ?? (dict["albumname"] as? String)
            ?? (dict["AlbumName"] as? String) ?? (dict["Album"] as? String)
            ?? (dict["album"] as? String) ?? ""
        var artist = (dict["artist_name"] as? String) ?? (dict["singername"] as? String)
            ?? (dict["SingerName"] as? String) ?? (dict["author"] as? String) ?? ""
        if artist.isEmpty, let fallbackSinger, !fallbackSinger.isEmpty, fallbackSinger != "未知歌手" {
            artist = fallbackSinger
        }
        // ⚠️★ 2026-10-14：这段原本是**一个 6 连 `??` 的长表达式**，在 Xcode 26.3 的
        // 类型检查器上直接超时（CI 日志原文）：
        //   KugouMusicAPI.swift:91:13: error: the compiler is unable to type-check
        //   this expression in reasonable time
        // 原因：`??` 对每个操作数都有「返回 T」与「返回 T?」两个重载，6 连时会给出
        // 2^5 = 32 种组合，叠加 `as?` 强制转换与 `map { String($0) }` 闭包，约束求解
        // 直接爆掉（同文件里 4 连的版本都没事）。
        // 修法：拆成两段**短链**，语义完全不变 —— 依旧是「第一个非 nil 的字符串胜出」，
        // 且各段的候选键顺序与原表达式逐一对应：
        //   ① 字符串键：album_id → albumid → AlbumID
        //   ② 数值键（JSON 里同一字段可能是 Int/Double/String）：AlbumID → album_id → albumid
        // 显式标注 `String?` 是为了钉死 `??` 的重载选择（去掉推断的歧义）。
        let albumIdText: String? = (dict["album_id"] as? String)
            ?? (dict["albumid"] as? String)
            ?? (dict["AlbumID"] as? String)
        let albumIdFromNumber: String? = Self.intValue(dict["AlbumID"]).map { String($0) }
            ?? Self.intValue(dict["album_id"]).map { String($0) }
            ?? Self.intValue(dict["albumid"]).map { String($0) }
        let albumId: String = albumIdText ?? albumIdFromNumber ?? ""
        let duration = TimeInterval(Self.intValue(dict["duration"])
            ?? Self.intValue(dict["timelength"])
            ?? Self.intValue(dict["Duration"]) ?? 0)

        return MusicItem(
            source: .kugou,
            title: title,
            artist: artist.isEmpty ? nil : artist,
            album: albumName,
            albumCoverURL: Self.coverURL(from: dict, albumId: albumId),
            duration: duration,
            kugouHash: hash,
            platformAlbumId: albumId.isEmpty ? nil : albumId
        )
    }

    /// 封面回退链：Image/AlbumImage/Img（song_search_v2 键名）→ imgUrl → album_pic → cover
    /// → imgurl → trans_param.union_cover → 按 albumId 拼图床。
    private static func coverURL(from dict: [String: Any], albumId: String) -> String? {
        for key in ["Image", "image", "AlbumImage", "Img", "img", "imgUrl", "album_pic", "cover", "imgurl", "singer_pic"] {
            if let raw = dict[key] as? String, !raw.isEmpty, let normalized = raw.kugouNormalizedImage {
                return normalized
            }
        }
        if let trans = dict["trans_param"] as? [String: Any],
           let union = trans["union_cover"] as? String, !union.isEmpty {
            return union.replacingOccurrences(of: "{size}", with: "400")
        }
        guard !albumId.isEmpty else { return nil }
        return "https://imge.kugou.com/stdmusic/400/album/\(albumId).jpg"
    }

    /// 从任意数值类型安全取整（JSON 里同一个字段可能是 Int 也可能是 Double）。
    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// 从 `歌手 - 歌名.mp3` 形式的 filename 里提取歌名。
    private static func titleFromFilename(_ filename: String?) -> String {
        guard let filename, !filename.isEmpty else { return "未知歌曲" }
        let parts = filename.components(separatedBy: " - ")
        if parts.count >= 2 {
            return parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        }
        return filename
    }

    // MARK: - 封面

    /// 专辑封面。此前误用 `img.kugou.com/stand/...`，正确图床是 `imge.kugou.com/stdmusic/400/album/...`。
    func albumCover(albumId: String?) -> String? {
        guard let albumId, !albumId.isEmpty else { return nil }
        return "https://imge.kugou.com/stdmusic/400/album/\(albumId).jpg"
    }

    // MARK: - 播放地址（play/getdata）

    func resolvePlayURL(item: MusicItem, quality: WellAudioQuality) async throws -> String {
        guard let hash = item.kugouHash ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        // `quality` 让服务端返回对应码率的 play_url（128/320/flac/high）
        let url = "https://wwwapi.kugou.com/yy/index.php?" +
            "r=play/getdata&hash=\(hash)&album_id=&mid=\(UUID().uuidString.lowercased())&platid=4" +
            "&quality=\(quality.kugouBitrate)&_=\(ts)"
        let resp = try await NetworkClient.shared.get(url, headers: headers)
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let playURL = data["play_url"] as? String, !playURL.isEmpty else {
            throw NetworkClient.NetworkError.noData
        }
        return playURL
    }

    // MARK: - 搜索歌手

    func searchArtists(keyword: String, limit: Int = 30) async throws -> [WellArtistSummary] {
        var result = await fetchSingerList(keyword: keyword, limit: limit)
        // 主接口为空时，退回「歌曲搜索 → 提取去重歌手」
        if result.isEmpty {
            result = await artistsFromSongSearch(keyword: keyword)
        }
        let trimmed = Array(result.prefix(limit))
        return await fillArtistAvatars(trimmed)
    }

    private func fetchSingerList(keyword: String, limit: Int) async -> [WellArtistSummary] {
        let url = "http://mobilecdn.kugou.com/api/v3/search/singer?" +
            "format=json&keyword=\(kugouEncode(keyword))&page=1&pagesize=\(limit)"
        guard let resp = try? await NetworkClient.shared.get(url, headers: headers),
              let json = NetworkClient.jsonObject(resp.data) else { return [] }

        var list: [[String: Any]] = []
        if let arr = json["data"] as? [[String: Any]] {
            list = arr
        } else if let dict = json["data"] as? [String: Any],
                  let info = dict["info"] as? [[String: Any]] {
            list = info
        }
        return list.compactMap { parseArtist($0) }
    }

    /// 从歌曲搜索结果中提取去重歌手（酷狗歌手接口不稳定时的兜底）。
    private func artistsFromSongSearch(keyword: String) async -> [WellArtistSummary] {
        let url = "https://songsearch.kugou.com/song_search_v2?" +
            "keyword=\(kugouEncode(keyword))&page=1&pagesize=30&userid=0" +
            "&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1"
        guard let resp = try? await NetworkClient.shared.get(url, headers: headers),
              let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let lists = data["lists"] as? [[String: Any]] else { return [] }

        var seen = Set<String>()
        var out: [WellArtistSummary] = []
        for song in lists {
            guard let singers = song["Singers"] as? [[String: Any]] else { continue }
            for singer in singers {
                let id = (singer["id"] as? Int).map(String.init) ?? (singer["id"] as? String) ?? ""
                let name = (singer["name"] as? String) ?? ""
                guard !id.isEmpty, !name.isEmpty, !seen.contains(id) else { continue }
                seen.insert(id)
                var pic = (singer["pic"] as? String)?.kugouNormalizedImage
                if pic == nil {
                    pic = "https://singerimg.kugou.com/uploadpic/softhead/400/\(id).jpg"
                }
                out.append(WellArtistSummary(
                    id: id, name: name, picURL: pic,
                    platform: .kugou, mid: id, subtitle: nil))
            }
        }
        return out
    }

    private func parseArtist(_ dict: [String: Any]) -> WellArtistSummary? {
        let id = (dict["singerid"] as? Int).map(String.init)
            ?? (dict["singer_id"] as? Int).map(String.init)
            ?? (dict["singerid"] as? String) ?? (dict["artist_id"] as? String) ?? ""
        let name = (dict["singername"] as? String) ?? (dict["artist_name"] as? String)
            ?? (dict["name"] as? String) ?? (dict["SingerName"] as? String) ?? ""
        guard !id.isEmpty, !name.isEmpty else { return nil }
        var pic = (dict["imgurl"] as? String)?.kugouNormalizedImage
            ?? (dict["singer_pic"] as? String)?.kugouNormalizedImage
            ?? (dict["avatar"] as? String)?.kugouNormalizedImage
        if pic == nil {
            pic = "https://singerimg.kugou.com/uploadpic/softhead/400/\(id).jpg"
        }
        let works = (dict["songcount"] as? Int) ?? (dict["song_num"] as? Int) ?? 0
        return WellArtistSummary(
            id: id, name: name, picURL: pic,
            platform: .kugou, mid: id,
            subtitle: works > 0 ? "\(works) 首单曲" : nil)
    }

    /// 并发补全前 10 个歌手的真实头像（默认图床多为占位图）。
    private func fillArtistAvatars(_ list: [WellArtistSummary]) async -> [WellArtistSummary] {
        var out = list
        let needCount = min(out.count, 10)
        await withTaskGroup(of: (Int, String?).self) { group in
            for i in 0..<needCount {
                let id = out[i].id.replacingOccurrences(of: "kugou_", with: "")
                group.addTask { (i, await Self.artistAvatar(singerId: id, headers: self.headers)) }
            }
            for await (index, avatar) in group {
                if let avatar, !avatar.isEmpty, index < out.count {
                    out[index].picURL = avatar
                }
            }
        }
        return out
    }

    private static func artistAvatar(singerId: String, headers: [String: String]) async -> String? {
        let url = "http://mobilecdn.kugou.com/api/v3/singer/info?singerid=\(singerId)"
        guard let resp = try? await NetworkClient.shared.get(url, headers: headers),
              let json = NetworkClient.jsonObject(resp.data),
              let info = json["data"] as? [String: Any],
              let img = info["imgurl"] as? String, !img.isEmpty else { return nil }
        return img.kugouNormalizedImage
    }

    // MARK: - 搜索专辑

    func searchAlbums(keyword: String, limit: Int = 30) async throws -> [WellAlbumSummary] {
        let url = "http://mobilecdn.kugou.com/api/v3/search/album?" +
            "format=json&keyword=\(kugouEncode(keyword))&page=1&pagesize=\(limit)"
        let resp = try await NetworkClient.shared.get(url, headers: headers)
        guard let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let list = data["info"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { item in
            let albumId = (item["albumid"] as? String) ?? (item["album_id"] as? String)
                ?? (item["albumid"] as? Int).map(String.init) ?? ""
            let name = (item["albumname"] as? String) ?? (item["album_name"] as? String) ?? ""
            guard !name.isEmpty, !albumId.isEmpty else { return nil }
            let singer = (item["singername"] as? String)
                ?? (item["artist_name"] as? String) ?? "未知歌手"
            var pic = (item["imgurl"] as? String)?.kugouNormalizedImage
                ?? (item["album_pic"] as? String)?.kugouNormalizedImage
            if pic == nil { pic = "https://imge.kugou.com/stdmusic/400/album/\(albumId).jpg" }
            return WellAlbumSummary(
                id: albumId, name: name, picURL: pic, artistName: singer,
                platform: .kugou, albumMid: albumId)
        }
    }

    // MARK: - 歌手详情（头像 + 热门歌曲）

    /// 获取歌手详情。返回 `(singerName, avatar, songs)`。
    func singerDetail(singerId: String) async throws -> (name: String, avatar: String?, songs: [MusicItem]) {
        let id = singerId.replacingOccurrences(of: "kugou_", with: "")

        // 1) 基本信息
        var singerName = ""
        var avatar: String?
        let infoURL = "http://mobilecdn.kugou.com/api/v3/singer/info?singerid=\(id)"
        if let resp = try? await NetworkClient.shared.get(infoURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let info = json["data"] as? [String: Any] {
            singerName = (info["singername"] as? String) ?? ""
            avatar = (info["imgurl"] as? String)?.kugouNormalizedImage
        }
        if avatar == nil {
            avatar = "https://singerimg.kugou.com/uploadpic/softhead/400/\(id).jpg"
        }

        // 2) 热门歌曲
        let songURL = "http://mobilecdn.kugou.com/api/v3/singer/song?singerid=\(id)&page=1&pagesize=50"
        var songs: [MusicItem] = []
        if let resp = try? await NetworkClient.shared.get(songURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let data = json["data"] as? [String: Any],
           let info = data["info"] as? [[String: Any]] {
            songs = info.compactMap { parseSong($0, fallbackSinger: singerName) }
        }
        return (singerName, avatar, songs)
    }

    /// 歌手歌曲分页（展开全部懒加载用）。
    func singerSongs(singerId: String, page: Int = 1, limit: Int = 30) async throws -> (list: [MusicItem], total: Int) {
        let id = singerId.replacingOccurrences(of: "kugou_", with: "")
        let url = "http://mobilecdn.kugou.com/api/v3/singer/song?singerid=\(id)&page=\(page)&pagesize=\(limit)"
        guard let resp = try? await NetworkClient.shared.get(url, headers: headers),
              let json = NetworkClient.jsonObject(resp.data),
              let data = json["data"] as? [String: Any],
              let info = data["info"] as? [[String: Any]] else {
            return ([], 0)
        }
        let singerName = (info.first?["singername"] as? String) ?? ""
        let list = info.compactMap { parseSong($0, fallbackSinger: singerName) }
        return (list, (data["total"] as? Int) ?? 0)
    }

    /// 歌手专辑（v5 接口，参考 Kumone KugouAPI.artistAlbums：循环分页拉全量，含 EP/单曲）。
    func artistAlbums(singerId: String, page: Int = 1, limit: Int = 30) async throws -> (list: [WellAlbumSummary], total: Int, hasMore: Bool) {
        let id = singerId.replacingOccurrences(of: "kugou_", with: "")
        let singerName = (try? await singerDetail(singerId: id).name) ?? ""

        var allAlbums: [WellAlbumSummary] = []
        var total = 0
        var currentPage = page
        let pageSize = 30

        while true {
            let url = "http://mobiles.kugou.com/api/v5/singer/album?singerid=\(id)&page=\(currentPage)&pagesize=\(pageSize)"
            guard let resp = try? await NetworkClient.shared.get(url, headers: headers),
                  let json = NetworkClient.jsonObject(resp.data),
                  let data = json["data"] as? [String: Any],
                  let info = data["info"] as? [[String: Any]] else {
                break
            }
            if total == 0 {
                total = (data["total"] as? Int) ?? info.count
            }
            let pageAlbums = info.compactMap { item -> WellAlbumSummary? in
                let albumIdText: String? = (item["albumid"] as? String) ?? (item["album_id"] as? String)
                let albumIdNumber = Self.intValue(item["albumid"]).map { String($0) }
                    ?? Self.intValue(item["album_id"]).map { String($0) }
                let albumId = albumIdText ?? albumIdNumber ?? ""
                let name = (item["albumname"] as? String) ?? (item["album_name"] as? String) ?? ""
                guard !name.isEmpty, !albumId.isEmpty else { return nil }
                var pic = (item["imgurl"] as? String)?.kugouNormalizedImage
                    ?? (item["album_pic"] as? String)?.kugouNormalizedImage
                if pic == nil { pic = "https://imge.kugou.com/stdmusic/400/album/\(albumId).jpg" }
                // 专辑类型：按歌曲数量区分（1首=单曲，2-5首=EP），不过滤全部返回
                var subType = "专辑"
                if let songCount = Self.intValue(item["songcount"]) {
                    if songCount == 1 { subType = "单曲" }
                    else if songCount > 1 && songCount <= 5 { subType = "EP" }
                }
                let publishTime = Self.intValue(item["publish_time"]).map { $0 * 1000 }
                return WellAlbumSummary(
                    id: albumId, name: name, picURL: pic,
                    artistName: singerName.isEmpty ? "未知歌手" : singerName,
                    platform: .kugou, albumMid: albumId,
                    albumType: subType, publishTime: publishTime)
            }
            allAlbums.append(contentsOf: pageAlbums)
            // 从 page 起最多循环到 10 页（300 张），防止无限循环
            if info.count < pageSize || currentPage >= page + 9 { break }
            currentPage += 1
        }
        let hasMore = allAlbums.count < total
        return (allAlbums, total, hasMore)
    }

    // MARK: - 专辑详情（歌曲列表）

    /// 获取专辑歌曲列表。返回 `(albumName, cover, songs)`。
    func albumDetail(albumId: String) async throws -> (name: String, cover: String?, songs: [MusicItem]) {
        let id = albumId.replacingOccurrences(of: "kugou_album_", with: "")
            .replacingOccurrences(of: "kugou_", with: "")

        var albumName = "未知专辑"
        var cover: String?
        let infoURL = "http://mobilecdn.kugou.com/api/v3/album/info?albumid=\(id)"
        if let resp = try? await NetworkClient.shared.get(infoURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let info = json["data"] as? [String: Any] {
            albumName = (info["albumname"] as? String) ?? (info["album_name"] as? String) ?? albumName
            cover = (info["imgurl"] as? String)?.kugouNormalizedImage
        }
        if cover == nil { cover = "https://imge.kugou.com/stdmusic/400/album/\(id).jpg" }

        var albumArtist = "未知歌手"
        if let resp = try? await NetworkClient.shared.get(infoURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let info = json["data"] as? [String: Any] {
            albumArtist = (info["singername"] as? String) ?? albumArtist
        }

        let songURL = "http://mobilecdn.kugou.com/api/v3/album/song?albumid=\(id)&page=1&pagesize=100"
        var songs: [MusicItem] = []
        if let resp = try? await NetworkClient.shared.get(songURL, headers: headers),
           let json = NetworkClient.jsonObject(resp.data),
           let data = json["data"] as? [String: Any],
           let info = data["info"] as? [[String: Any]] {
            songs = info.compactMap { parseSong($0, fallbackSinger: albumArtist) }
        }
        return (albumName, cover, songs)
    }

    private func kugouEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

private extension String {
    /// 酷狗图床地址归一化：`{size}` 替换 + 协议补全。
    var kugouNormalizedImage: String? {
        guard !isEmpty else { return nil }
        var s = replacingOccurrences(of: "{size}", with: "400")
        if s.hasPrefix("//") { s = "https:" + s }
        s = s.replacingOccurrences(of: "http://", with: "https://")
        return s
    }
}
