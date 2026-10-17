import SwiftUI
import UIKit
import VariableBlurImageView

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
    /// 贴底对齐：页面背景用——显示封面**底边**那一截，视觉上从封面延伸下来
    var alignBottom: Bool = false

    @State private var rendered: UIImage?

    var body: some View {
        ZStack {
            if let rendered {
                Image(uiImage: rendered)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: alignBottom ? .bottom : .center)
                    .clipped()
            } else if let cached = url.flatMap({ WellImageCache.shared.syncCachedImage(for: $0) }) {
                // 合成完成前的过渡（视觉上不突兀）
                Image(uiImage: cached)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24, opaque: true)
            } else if let url {
                // ★ 2026-10-17：Metal 合成还没完成/失败时，**必须**有可见回退，
                //   否则整块区域空白（用户「歌手头像呢」）。用远程图 + 轻模糊顶上。
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill().blur(radius: 18, opaque: true)
                    } else {
                        Color.secondary.opacity(0.12)
                    }
                }
            } else {
                Color.secondary.opacity(0.12)
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
        // ★ 2026-10-17 用户指定 Eskils/VariableBlurImageView：Metal 真·可变模糊
        //   （半径沿纵向连续变化 0 → maxRadius），比「均匀模糊 + 渐变混合」更接近 Apple Music。
        //   引擎吃/吐 CGImage（已核对源码签名：applyVerticalVariableBlur(toImage:...) throws -> CGImage）。
        guard let cg = image.cgImage else { return nil }
        let h = CGFloat(cg.height)
        let startPoint = max(0, min(h, h * start))
        let engine = VariableBlurEngine()
        guard let out = try? engine.applyVerticalVariableBlur(
            toImage: cg,
            startPoint: startPoint,
            endPoint: h,
            startRadius: 0,
            endRadius: maxRadius) else { return nil }
        return UIImage(cgImage: out)
    }
}
