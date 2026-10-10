import Foundation

/// 网易云音乐 API（weapi 加密版）
final class NeteaseMusicAPI {
    static let shared = NeteaseMusicAPI()

    init() {}

    // MARK: 模型

    private struct SearchResponse: Decodable {
        var code: Int?
        var result: Result?
        struct Result: Decodable {
            var songs: [Song]?
        }
    }

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

    private struct URLResponse: Decodable {
        var code: Int?
        var data: [URLItem]?
        struct URLItem: Decodable {
            var url: String?
            var br: Int?
        }
    }

    // MARK: 搜索

    func search(keyword: String, limit: Int = 30) async throws -> [MusicItem] {
        let params: [String: Any] = [
            "s": keyword,
            "type": 1,
            "offset": 0,
            "limit": limit,
            "total": true,
            "csrf_token": "",
        ]
        let resp: SearchResponse = try await NeteaseCrypto.weapi(
            "weapi/cloudsearch/get/web", params: params, type: SearchResponse.self)
        guard resp.code == 200 else { throw NetworkClient.NetworkError.badStatus(resp.code ?? -1) }
        return (resp.result?.songs ?? []).compactMap { song in
            guard let id = song.id, let name = song.name else { return nil }
            return MusicItem(
                source: .netease,
                title: name,
                artist: song.ar?.first?.name ?? song.ar?.compactMap { $0.name }.joined(separator: "/"),
                album: song.al?.name,
                albumCoverURL: song.al?.picUrl,
                duration: TimeInterval(song.dt ?? 0) / 1000,
                neteaseId: "\(id)"
            )
        }
    }

    // MARK: 播放地址（weapi 音质：exhigh 无损 / standard 标准）

    func resolvePlayURL(item: MusicItem, highQuality: Bool) async throws -> String {
        guard let id = item.neteaseId ?? item.platformId else {
            throw NetworkClient.NetworkError.noData
        }
        let params: [String: Any] = [
            "ids": "[\(id)]",
            "level": highQuality ? "exhigh" : "standard",
            "encodeType": "mp3",
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
}