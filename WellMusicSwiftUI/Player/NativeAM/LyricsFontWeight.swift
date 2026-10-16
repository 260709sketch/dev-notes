import SwiftUI
import UIKit

enum LyricsFontWeight: String, CaseIterable, Identifiable {
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "细体"
        case .regular: "常规"
        case .medium: "中等"
        case .semibold: "半粗"
        case .bold: "粗体"
        case .heavy: "特粗"
        }
    }

    var swiftUIWeight: Font.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    var uiKitWeight: UIFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}
