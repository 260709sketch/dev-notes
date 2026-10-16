import Foundation

enum LyricsTranslationDisplayMode: String, CaseIterable, Identifiable {
    case focusedLine
    case allLines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focusedLine:
            "仅焦点行"
        case .allLines:
            "全部行"
        }
    }
}
