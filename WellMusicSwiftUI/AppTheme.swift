import SwiftUI

/// 全局主题：跟随系统深/浅色，主色为网易云系红色
enum AppTheme {
    /// 主题红
    static let accent = Color(red: 0.93, green: 0.25, blue: 0.24)

    /// 全页兜底背景色（覆盖 MainTabView 根、各 Tab 页面、Settings 等所有 page 兜底）。
    ///
    /// 必须是 **systemGroupedBackground**，不能用 systemBackground：
    ///   * systemBackground（light = #FFFFFF）会让 nav bar / tab bar 与 List 行块
    ///     之间的"白条"明显可见（详见 `WellMusicApp.bootstrapNavBarAppearance`）；
    ///   * systemGroupedBackground（light = #F2F2F7）与 List(.insetGrouped) 行块的
    ///     secondarySystemGroupedBackground（白）天然分层，又不会跟 nav bar / tab bar
    ///     形成色差 —— iOS 26 液态玻璃 tab bar 模糊下层后显同浅灰，整体一致。
    static let background = Color(uiColor: .systemGroupedBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let tertiaryBackground = Color(uiColor: .tertiarySystemBackground)
    static let separator = Color(uiColor: .separator)

    /// 歌词/封面悬浮渐变背景底色
    static let nowPlayingBackgroundTop = Color(red: 0.12, green: 0.10, blue: 0.14)
    static let nowPlayingBackgroundBottom = Color(red: 0.03, green: 0.03, blue: 0.05)

    /// 主要文字
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// 从图片提取主色调（替代原 react-native-image-colors）
extension UIImage {
    /// 取平均主色，供播放页背景渐变使用
    func dominantColor() -> UIColor {
        guard let cgImage = cgImage else { return UIColor(red: 0.12, green: 0.10, blue: 0.14, alpha: 1) }
        let size = CGSize(width: 32, height: 32)
        UIGraphicsBeginImageContext(size)
        self.draw(in: CGRect(origin: .zero, size: size))
        guard let resized = UIGraphicsGetImageFromCurrentImageContext()?.cgImage else {
            UIGraphicsEndImageContext()
            return UIColor(red: 0.12, green: 0.10, blue: 0.14, alpha: 1)
        }
        UIGraphicsEndImageContext()
        var totalR = 0.0, totalG = 0.0, totalB = 0.0
        var count = 0
        let width = resized.width, height = resized.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return UIColor(red: 0.12, green: 0.10, blue: 0.14, alpha: 1)
        }
        ctx.draw(resized, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: data.count, by: 4) {
            let b = Double(data[i]), g = Double(data[i + 1]), r = Double(data[i + 2])
            totalR += r; totalG += g; totalB += b; count += 1
        }
        guard count > 0 else { return UIColor(red: 0.12, green: 0.10, blue: 0.14, alpha: 1) }
        return UIColor(red: CGFloat(totalR / Double(count) / 255.0),
                       green: CGFloat(totalG / Double(count) / 255.0),
                       blue: CGFloat(totalB / Double(count) / 255.0),
                       alpha: 1)
    }
}