import Foundation

/// 聚合搜索服务：并行请求各平台，按来源分组
@MainActor
final class SearchService {
    static let shared = SearchService()
    private init() {}

    func search(keyword: String, limit: Int = 30) async -> [SearchView.SearchResultSection] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }

        async let qq = searchPlatform(.qq, keyword: key, limit: limit)
        async let netease = searchPlatform(.netease, keyword: key, limit: limit)
        async let kugou = searchPlatform(.kugou, keyword: key, limit: limit)
        async let kuwo = searchPlatform(.kuwo, keyword: key, limit: limit)

        let all: [(MusicSource, [MusicItem])] = await [
            (.qq, qq), (.netease, netease), (.kugou, kugou), (.kuwo, kuwo),
        ]

        return all
            .filter { !$0.1.isEmpty }
            .map { source, items in
                SearchView.SearchResultSection(title: source.displayName, items: items)
            }
    }

    private func searchPlatform(_ source: MusicSource, keyword: String, limit: Int) async -> [MusicItem] {
        do {
            switch source {
            case .qq: return try await QQMusicAPI.shared.search(keyword: keyword, limit: limit)
            case .netease: return try await NeteaseMusicAPI.shared.search(keyword: keyword, limit: limit)
            case .kugou: return try await KugouMusicAPI.shared.search(keyword: keyword, limit: limit)
            case .kuwo: return try await KuwoMusicAPI.shared.search(keyword: keyword, limit: limit)
            case .auto:
                return try await NeteaseMusicAPI.shared.search(keyword: keyword, limit: limit)
            }
        } catch {
            return []
        }
    }
}