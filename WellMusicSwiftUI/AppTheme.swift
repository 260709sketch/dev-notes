import SwiftUI

/// 全局主题：跟随系统深/浅色，主色为网易云系红色
enum AppTheme {
    /// 主题红
    static let accent = Color(red: 0.93, green: 0.25, blue: 0.24)

    /// 全 App 背景色（MainTabView 根、各 page 兜底）。
    /// 跟老版本一致保留 systemBackground：app 整体强制 dark，**深色下是黑**，
    /// 配合老版本 .preferredColorScheme(.dark) 的设置（见 WellMusicApp.body），
    /// nav bar / tab bar / 页面**统一全黑**——"白条"从源头不存在。
    /// 若未来想支持浅色模式，需同步把 nav bar / tab bar 也铺同色，否则会复现断层。
    static let background = Color(uiColor: .systemBackground)
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

/// ★ 移除顶部/底部「白色遮挡」的 chrome 背景隐藏开关。
///
/// 用户实测：dock 栏（tab bar）下方与页面顶部各有一块**白色遮挡**，挡住了
/// 延伸到这些区域的内容。这两块是系统 nav bar / tab bar 的 chrome 背景底座，
/// 必须隐藏（不是变色）。iOS 18+ 的 `toolbarBackgroundVisibility(.hidden,
/// for: .automatic)` 一次性隐藏 nav bar + tab bar + 搜索栏底座；
/// iOS 16-17 退回逐个隐藏。
struct HiddenChromeBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .automatic)
        } else {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarBackground(.hidden, for: .tabBar)
        }
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
            // ⚠️ 字节序（2026-10-14 修复）：`premultipliedLast` 在 iOS 上的内存布局是
            //    **RGBA**（R 在低位），与同项目 FluidGradientBackground 的读取顺序一致。
            //    旧代码把 data[i] 当 B、data[i+2] 当 R 读 —— 红蓝通道互换，
            //    粉色封面会提取成偏蓝色（用户实机发现「哪里来的蓝色」的根因）。
            let r = Double(data[i]), g = Double(data[i + 1]), b = Double(data[i + 2])
            totalR += r; totalG += g; totalB += b; count += 1
        }
        guard count > 0 else { return UIColor(red: 0.12, green: 0.10, blue: 0.14, alpha: 1) }
        return UIColor(red: CGFloat(totalR / Double(count) / 255.0),
                       green: CGFloat(totalG / Double(count) / 255.0),
                       blue: CGFloat(totalB / Double(count) / 255.0),
                       alpha: 1)
    }
}