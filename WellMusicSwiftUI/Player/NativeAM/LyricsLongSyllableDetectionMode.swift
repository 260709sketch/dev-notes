import Foundation

enum LyricsLongSyllableDetectionMode:
    String, CaseIterable, Identifiable, Sendable {
    case word
    case character

    var id: String { rawValue }

    var title: String {
        switch self {
        case .word:
            "按词"
        case .character:
            "按字"
        }
    }
}
