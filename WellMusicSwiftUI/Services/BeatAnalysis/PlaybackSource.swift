import Foundation

/// ★ 2026-10-16 节拍分析一期：从 MeloX `PlaybackSource` 精简而来
/// （只保留分析管线用到的 url / format）。
struct PlaybackSource: Equatable, Sendable {
    let url: URL
    let format: String?

    init(url: URL, format: String? = nil) {
        self.url = url
        self.format = format
    }
}
