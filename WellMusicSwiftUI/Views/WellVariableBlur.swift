import SwiftUI
import CoreImage
import UIKit

/// 可变模糊背景（VariableBlur 同款技术，Apple Music 头图那种「上清晰 → 下渐糊」）。
///
/// 原理：CIGaussianBlur 出一张强模糊图 + CILinearGradient 做遮罩 +
/// CIBlendWithMask 把「清晰图」和「模糊图」按渐变混合 —— 模糊半径在纵向
/// 连续增大，接缝天然不存在（比「均匀 blur + 渐隐」更接近 Apple 观感）。
/// 合成结果按 URL 内存缓存，只在换封面时算一次。
struct WellVariableBlur: View {
    let url: URL?
    /// 最大模糊 σ（越大越糊）
    var maxRadius: CGFloat = 28
    /// 从该相对高度开始变糊（0 顶 → 1 底）
    var start: CGFloat = 0.30

    @State private var rendered: UIImage?

    var body: some View {
        ZStack {
            if let rendered {
                Image(uiImage: rendered)
                    .resizable()
                    .scaledToFill()
            } else if let cached = url.flatMap({ WellImageCache.shared.syncCachedImage(for: $0) }) {
                // 合成完成前的过渡（视觉上不突兀）
                Image(uiImage: cached)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24, opaque: true)
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .task(id: url) { await render() }
    }

    private func render() async {
        guard let url else { return }
        let key = url.absoluteString + "|\(maxRadius)|\(start)"
        if let hit = Self.cache[key] {
            rendered = hit
            return
        }
        guard let base = await WellImageCache.shared.image(for: url) else { return }
        if let out = Self.composite(base, maxRadius: maxRadius, start: start) {
            Self.cache[key] = out
            rendered = out
        }
    }

    @MainActor private static var cache: [String: UIImage] = [:]

    private static func composite(_ image: UIImage, maxRadius: CGFloat, start: CGFloat) -> UIImage? {
        guard let ci = CIImage(image: image) else { return nil }
        let extent = ci.extent
        // 大半径高斯模糊（clamped 防止边缘透明）
        let blur = ci.clampedToExtent()
            .applyingGaussianBlur(sigma: maxRadius)
            .cropped(to: extent)
        // 纵向渐变遮罩：start 处黑（显示清晰层）→ 底部白（显示模糊层）
        guard let gradient = CIFilter(name: "CILinearGradient",
                                      parameters: [
                                        "inputPoint0": CIVector(x: extent.midX,
                                                                y: extent.minY + extent.height * (1 - start)),
                                        "inputPoint1": CIVector(x: extent.midX, y: extent.minY),
                                        "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                                        "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                                      ])?.outputImage else { return nil }
        let mask = gradient.cropped(to: extent)
        guard let blended = CIFilter(name: "CIBlendWithMask",
                                     parameters: [
                                        kCIInputImageKey: blur,
                                        kCIInputBackgroundImageKey: ci,
                                        kCIInputMaskImageKey: mask,
                                     ])?.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(blended, from: extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
