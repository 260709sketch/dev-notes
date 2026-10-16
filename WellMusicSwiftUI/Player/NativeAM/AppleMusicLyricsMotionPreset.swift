import Foundation

enum AppleMusicLyricsMotionPreset: String, CaseIterable, Identifiable {
    case appleMusic26
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleMusic26:
            "Apple Music 26"
        case .custom:
            "自定义"
        }
    }

    var description: String {
        switch self {
        case .appleMusic26:
            "mobile_detail"
        case .custom:
            "detail"
        }
    }
}
