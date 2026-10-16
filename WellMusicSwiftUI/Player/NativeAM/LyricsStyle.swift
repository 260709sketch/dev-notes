import Foundation

enum LyricsStyle: String, CaseIterable, Identifiable {
    case appleMusic
    case eva
    case textPV

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMusic: "apple_music"
        case .eva: "eva"
        case .textPV: "text_pv"
        }
    }

    var systemImage: String {
        switch self {
        case .appleMusic: "quote.bubble"
        case .eva: "rectangle.split.3x1.fill"
        case .textPV: "textformat.size.larger"
        }
    }

    var description: String {
        switch self {
        case .appleMusic: "detail"
        case .eva: "detail"
        case .textPV: "detail"
        }
    }

    var usesMonochromePlayerBackground: Bool {
        switch self {
        case .eva, .textPV: true
        case .appleMusic: false
        }
    }
}
