import SwiftUI
import UIKit

// MARK: - AMLL 同款「四色流体渐变」背景（原生实现）
//
// 参考对象：Steve-xmh/applemusic-like-lyrics 的 MeshGradientRenderer（MIT）。
// 我们**没有搬运它的代码**（那是 TypeScript + WebGL），只对齐它的观感与管线，
// 用 Swift 在 CPU 上重写 —— 代码结构与命名都是本项目自己的。
//
// AMLL 的管线（我们对齐的部分）：
//   1. 封面缩到 32×32，做「对比度 0.4 → 饱和度 3.0 → 对比度 1.7 → 亮度 0.75」
//      的像素增强，再盒模糊 —— 得到一张高饱和、色块分明的取色纹理；
//   2. 每个状态（每次切歌）随机生成一组**网格扭曲场**：纹理不是平铺采样，
//      而是先经一个平滑的低频形变（这就是画面里那几团「四色」的来源）；
//   3. 逐帧把采样 UV 绕画面中心**慢速旋转**（约 0.2 rad/s，呼吸般缓慢），
//      叠加暗角（中心 1.0 → 边缘 0.6）与抖动去色带；
//   4. 切歌时新旧两层用 easeInOutSine 交叉淡化。
//
// 性能设计（用户明确要求「分辨率调整到很低」）：
//   * 整个画面只在一张 **≈48×106 的 RGBA 位图**上逐帧计算（约五千个像素，
//     每帧 CPU < 2ms），再交给 GPU 一次性拉伸到全屏；
//   * CADisplayLink 锁 24fps，离屏（播放器关闭、进后台）自动停帧；
//   * 没有 WebView、没有 WebGL、没有 Metal —— 最重的一层是 UIImageView 换图。

struct FluidGradientBackground: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> FluidGradientView {
        let view = FluidGradientView()
        view.load(url: url)
        return view
    }

    func updateUIView(_ uiView: FluidGradientView, context: Context) {
        uiView.load(url: url)
    }
}

final class FluidGradientView: UIView {

    // MARK: 常量（与 AMLL 着色器数值一致）

    private enum Constants {
        /// UV 旋转速度（rad/s）。AMLL：angle = (tickTime/10000s + volume) * 2 → 0.2 rad/s。
        static let rotationSpeed: Float = 0.2
        /// 旋转前 UV 先减去的偏移（AMLL frag：`v_uv - vec2(0.2)`），让旋转中心略偏离画面中心。
        static let rotationOrigin: Float = 0.2
        /// 切歌交叉淡化时长（秒）。AMLL：alpha += delta/500ms，我们放缓到 0.6s 更从容。
        static let crossfadeSeconds: Double = 0.6
        /// 取色纹理边长（AMLL 的 reduceImageSizeCanvas 是 32×32）。
        static let textureSize = 32
        /// 扭曲场格点边数。
        static let warpGrid = 5
        /// 锁帧率。
        static let targetFPS: Int = 24
    }

    // MARK: 状态

    /// 一个「状态」= 一张取色纹理 + 一个扭曲场。切歌时新建一个并交叉淡入。
    private struct FluidState {
        var texture: [UInt8]      // 32×32 RGBA
        var warp: WarpField
        var alpha: Double = 0     // 0…1，淡入进度
    }

    /// 低频形变场：G×G 格点上的 UV 偏移，双三次 Catmull-Rom 插值。
    /// 边缘一圈恒为 0，保证画面边缘不会露出空隙。
    private struct WarpField {
        var size: Int
        var dx: [Float]
        var dy: [Float]
    }

    private var states: [FluidState] = []
    private var displayLink: CADisplayLink?
    private var bitmapContext: CGContext?
    private var bitmapWidth = 0
    private var bitmapHeight = 0
    private var elapsed: Double = 0
    private var lastTimestamp: CFTimeInterval = 0

    private var currentURL: URL?
    private var loadToken = 0
    private static let imageCache = NSCache<NSURL, UIImage>()
    private static let fetchQueue = DispatchQueue(label: "wellmusic.fluidbg", qos: .utility)

    // MARK: 视图结构

    private let imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleToFill
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        rebuildBitmapContextIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopLink()
        } else if !states.isEmpty {
            startLink()
        }
    }

    deinit {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: 对外：换封面

    func load(url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        loadToken += 1
        let token = loadToken

        guard let url else { return }

        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            adoptState(from: cached)
            return
        }

        // 向图床要一张小图（128 档足够取色用），网络与解码都在后台队列。
        let smallURL = WellArtworkURL.resolved(url.absoluteString, pixelSize: 128) ?? url
        Self.fetchQueue.async { [weak self] in
            guard let self, token == self.loadToken else { return }
            var image = Self.imageCache.object(forKey: smallURL as NSURL)
            if image == nil {
                image = Self.fetchImage(smallURL)
                if let image {
                    Self.imageCache.setObject(image, forKey: smallURL as NSURL)
                }
            }
            guard let image, token == self.loadToken else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.loadToken else { return }
                self.adoptState(from: image)
            }
        }
    }

    private func adoptState(from image: UIImage) {
        guard let texture = Self.makeTexture(from: image) else { return }
        let state = FluidState(texture: texture, warp: Self.makeWarpField())
        states.append(state)
        if states.count > 2 {
            states.removeFirst(states.count - 2)
        }
        if window != nil {
            startLink()
        }
    }

    // MARK: 图片获取

    private static func fetchImage(_ url: URL) -> UIImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("WellMusicSwiftUI", forHTTPHeaderField: "User-Agent")
        guard let data = try? URLSession.shared.dataSync(with: request).0, !data.isEmpty else {
            return nil
        }
        return UIImage(data: data)
    }

    // MARK: 取色纹理（对齐 AMLL 的像素增强 + 盒模糊）

    private static func makeTexture(from image: UIImage) -> [UInt8]? {
        let size = Constants.textureSize
        guard let cg = image.cgImage else { return nil }

        // 用 CG 自管理的内存（data: nil），算完再拷出来 —— 避免 Swift 数组
        // 指针被 CGContext 长期持有的生命周期问题。
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        // AMLL：drawImage(res, 0, 0, imgw, imgh, 0, 0, 32, 32) —— 整张拉伸铺满。
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        var data = [UInt8](repeating: 0, count: size * size * 4)
        data.withUnsafeMutableBytes { raw in
            raw.baseAddress?.copyMemory(from: base, byteCount: size * size * 4)
        }

        // 像素增强：contrast 0.4 → saturate 3.0 → contrast 1.7 → brightness 0.75
        // （数值逐项对齐 AMLL setAlbum 里的循环。）
        for i in stride(from: 0, to: data.count, by: 4) {
            var r = Float(data[i])
            var g = Float(data[i + 1])
            var b = Float(data[i + 2])

            r = (r - 128) * 0.4 + 128
            g = (g - 128) * 0.4 + 128
            b = (b - 128) * 0.4 + 128

            let gray = r * 0.3 + g * 0.59 + b * 0.11
            r = gray * -2.0 + r * 3.0
            g = gray * -2.0 + g * 3.0
            b = gray * -2.0 + b * 3.0

            r = (r - 128) * 1.7 + 128
            g = (g - 128) * 1.7 + 128
            b = (b - 128) * 1.7 + 128

            data[i] = UInt8(max(0, min(255, r * 0.75)))
            data[i + 1] = UInt8(max(0, min(255, g * 0.75)))
            data[i + 2] = UInt8(max(0, min(255, b * 0.75)))
            data[i + 3] = 255
        }

        boxBlur(&data, width: size, height: size, radius: 2, passes: 2)
        return data
    }

    /// 盒模糊（滑窗实现，横向 + 纵向算一趟 pass）。AMLL 用 radius=2、quality=4 的
    /// 全窗口模糊；32×32 的图上两趟分离模糊的平滑度与之足够接近，成本更低。
    private static func boxBlur(_ data: inout [UInt8], width: Int, height: Int, radius: Int, passes: Int) {
        let count = width * height
        var acc = [Float](repeating: 0, count: count * 4)
        var tmp = [Float](repeating: 0, count: count * 4)

        for i in 0..<(count * 4) {
            acc[i] = Float(data[i])
        }

        for _ in 0..<passes {
            // 横向
            for y in 0..<height {
                let row = y * width
                for c in 0..<4 {
                    var sum: Float = 0
                    for k in -radius...radius {
                        let x = max(0, min(width - 1, k))
                        sum += acc[(row + x) * 4 + c]
                    }
                    tmp[row * 4 + c] = sum / Float(radius * 2 + 1)
                    for x in 1..<width {
                        let addX = max(0, min(width - 1, x + radius))
                        let subX = max(0, min(width - 1, x - radius - 1))
                        sum += acc[(row + addX) * 4 + c] - acc[(row + subX) * 4 + c]
                        tmp[(row + x) * 4 + c] = sum / Float(radius * 2 + 1)
                    }
                }
            }
            // 纵向
            for x in 0..<width {
                for c in 0..<4 {
                    var sum: Float = 0
                    for k in -radius...radius {
                        let y = max(0, min(height - 1, k))
                        sum += tmp[(y * width + x) * 4 + c]
                    }
                    acc[x * 4 + c] = sum / Float(radius * 2 + 1)
                    for y in 1..<height {
                        let addY = max(0, min(height - 1, y + radius))
                        let subY = max(0, min(height - 1, y - radius - 1))
                        sum += tmp[(addY * width + x) * 4 + c] - tmp[(subY * width + x) * 4 + c]
                        acc[(y * width + x) * 4 + c] = sum / Float(radius * 2 + 1)
                    }
                }
            }
        }

        for i in 0..<(count * 4) {
            data[i] = UInt8(max(0, min(255, acc[i].rounded())))
        }
    }

    // MARK: 扭曲场生成

    /// 随机生成一组平滑形变：内部格点 ±0.18（UV 单位）随机偏移，边缘为 0，
    /// 再做两轮 3×3 二项式平滑（对齐 AMLL cp-generate 的 smoothify 思路）。
    private static func makeWarpField() -> WarpField {
        let g = Constants.warpGrid
        var dx = [Float](repeating: 0, count: g * g)
        var dy = [Float](repeating: 0, count: g * g)

        for j in 0..<g {
            for i in 0..<g {
                let border = (i == 0 || i == g - 1 || j == 0 || j == g - 1)
                guard !border else { continue }
                dx[j * g + i] = Float.random(in: -0.18...0.18)
                dy[j * g + i] = Float.random(in: -0.18...0.18)
            }
        }

        for _ in 0..<2 {
            dx = smooth3(dx, size: g)
            dy = smooth3(dy, size: g)
        }

        return WarpField(size: g, dx: dx, dy: dy)
    }

    private static func smooth3(_ field: [Float], size: Int) -> [Float] {
        var out = field
        let kernel: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1]
        for j in 0..<size {
            for i in 0..<size {
                if i == 0 || i == size - 1 || j == 0 || j == size - 1 { continue }
                var sum: Float = 0
                for dj in -1...1 {
                    for di in -1...1 {
                        sum += field[(j + dj) * size + (i + di)] * kernel[(dj + 1) * 3 + (di + 1)]
                    }
                }
                out[j * size + i] = sum / 16
            }
        }
        return out
    }

    /// Catmull-Rom 双三次插值采样形变场。
    private static func warpSample(_ field: [Float], size: Int, u: Float, v: Float) -> Float {
        let gx = max(0, min(Float(size - 1), u * Float(size - 1)))
        let gy = max(0, min(Float(size - 1), v * Float(size - 1)))
        let x0 = Int(gx.rounded(.down))
        let y0 = Int(gy.rounded(.down))
        let tx = gx - Float(x0)
        let ty = gy - Float(y0)

        let cx0 = max(0, min(size - 1, x0 - 1))
        let cx1 = max(0, min(size - 1, x0))
        let cx2 = max(0, min(size - 1, x0 + 1))
        let cx3 = max(0, min(size - 1, x0 + 2))
        let cy0 = max(0, min(size - 1, y0 - 1)) * size
        let cy1 = max(0, min(size - 1, y0)) * size
        let cy2 = max(0, min(size - 1, y0 + 1)) * size
        let cy3 = max(0, min(size - 1, y0 + 2)) * size

        let c0 = catmullRom(field[cy0 + cx0], field[cy0 + cx1], field[cy0 + cx2], field[cy0 + cx3], tx)
        let c1 = catmullRom(field[cy1 + cx0], field[cy1 + cx1], field[cy1 + cx2], field[cy1 + cx3], tx)
        let c2 = catmullRom(field[cy2 + cx0], field[cy2 + cx1], field[cy2 + cx2], field[cy2 + cx3], tx)
        let c3 = catmullRom(field[cy3 + cx0], field[cy3 + cx1], field[cy3 + cx2], field[cy3 + cx3], tx)
        return catmullRom(c0, c1, c2, c3, ty)
    }

    private static func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * ((2 * p1) + (-p0 + p2) * t
                      + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                      + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }

    // MARK: 帧驱动

    private func startLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFramesPerSecond = Constants.targetFPS
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }

    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard !states.isEmpty else {
            if imageView.image != nil { imageView.image = nil }
            return
        }
        if lastTimestamp == 0 { lastTimestamp = link.timestamp }
        let dt = min(0.1, link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp
        elapsed += dt

        // 淡入推进
        for i in states.indices {
            states[i].alpha = min(1, states[i].alpha + dt / Constants.crossfadeSeconds)
        }
        // 淡入完成后丢掉旧状态
        if states.count > 1, states.last?.alpha == 1 {
            states.removeFirst(states.count - 1)
        }

        renderFrame()
        if let cg = bitmapContext?.makeImage() {
            imageView.image = UIImage(cgImage: cg)
        }
    }

    // MARK: 位图

    private func rebuildBitmapContextIfNeeded() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        // 极低分辨率：宽 ≈ 屏宽/8（clamp 24…56），高按同比例。
        let w = max(24, min(56, Int(bounds.width / 8)))
        let h = max(48, min(140, Int(bounds.height / 8)))
        guard w != bitmapWidth || h != bitmapHeight else { return }
        bitmapWidth = w
        bitmapHeight = h
        bitmapContext = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: 逐像素渲染（对齐 AMLL 片元着色器）

    private func renderFrame() {
        rebuildBitmapContextIfNeeded()
        guard let ctx = bitmapContext, bitmapWidth > 0, bitmapHeight > 0 else { return }
        let w = bitmapWidth
        let h = bitmapHeight

        // AMLL：angle = (elapsed + volume) * 2，volume 未接 → 0.2 rad/s。
        let angle = Float(elapsed) * Constants.rotationSpeed
        let sinA = sin(angle)
        let cosA = cos(angle)

        // 切歌交叉淡化系数（easeInOutSine）
        var blend: Float = 1
        if states.count > 1, let alpha = states.last?.alpha {
            let t = min(1, max(0, alpha))
            blend = Float(-(cos(Double.pi * t) - 1) / 2)
        }

        guard let ptr = ctx.data else { return }
        let buf = ptr.assumingMemoryBound(to: UInt8.self)

        let hasOld = states.count > 1

        for y in 0..<h {
            let v = (Float(y) + 0.5) / Float(h)
            let rowBase = y * w * 4
            for x in 0..<w {
                let u = (Float(x) + 0.5) / Float(w)

                let colorNew = Self.stateColor(states[states.count - 1], u: u, v: v, sinA: sinA, cosA: cosA)
                var r = colorNew.0
                var g = colorNew.1
                var b = colorNew.2
                if hasOld {
                    let colorOld = Self.stateColor(states[0], u: u, v: v, sinA: sinA, cosA: cosA)
                    r = colorOld.0 + (r - colorOld.0) * blend
                    g = colorOld.1 + (g - colorOld.1) * blend
                    b = colorOld.2 + (b - colorOld.2) * blend
                }

                // 暗角：mask = 0.6 + smoothstep(0.8, 0.3, dist) * 0.4（中心亮、四角压暗 40%）
                let dxv = u - 0.5
                let dyv = v - 0.5
                let dist = sqrtf(dxv * dxv + dyv * dyv)
                var tv = (0.8 - dist) / 0.5
                tv = max(0, min(1, tv))
                let vig = tv * tv * (3 - 2 * tv)
                let mask = 0.6 + vig * 0.4

                // 抖动去色带（对齐 AMLL 的 gradientNoise）
                let dn = fract(52.9829189 * fract(Float(x) * 0.06711056 + Float(y) * 0.00583715))
                let dither = dn / 255 - 0.5 / 255

                let base = rowBase + x * 4
                buf[base] = UInt8(max(0, min(255, (r * mask + dither) * 255)))
                buf[base + 1] = UInt8(max(0, min(255, (g * mask + dither) * 255)))
                buf[base + 2] = UInt8(max(0, min(255, (b * mask + dither) * 255)))
                buf[base + 3] = 255
            }
        }
    }

    /// 单状态取色：UV → 扭曲场偏移 → 绕中心慢速旋转 → 32×32 纹理镜像重复采样。
    private static func stateColor(
        _ state: FluidState, u: Float, v: Float, sinA: Float, cosA: Float
    ) -> (Float, Float, Float) {
        let du = warpSample(state.warp.dx, size: state.warp.size, u: u, v: v)
        let dv = warpSample(state.warp.dy, size: state.warp.size, u: u, v: v)

        let uu = u + du
        let vv = v + dv

        // AMLL frag：centered = uv - 0.2；rotate；+0.5
        let cx = uu - Constants.rotationOrigin
        let cy = vv - Constants.rotationOrigin
        let rx = cosA * cx - sinA * cy
        let ry = sinA * cx + cosA * cy
        let fx = rx + 0.5
        let fy = ry + 0.5

        return sampleTexture(state.texture, fx: fx, fy: fy)
    }

    private static func sampleTexture(_ tex: [UInt8], fx: Float, fy: Float) -> (Float, Float, Float) {
        let n = Constants.textureSize
        let sx = mirrorRepeat(fx)
        let sy = mirrorRepeat(fy)

        let px = sx * Float(n) - 0.5
        let py = sy * Float(n) - 0.5
        let x0 = Int(px.rounded(.down))
        let y0 = Int(py.rounded(.down))
        let tx = px - Float(x0)
        let ty = py - Float(y0)
        let ix0 = max(0, min(n - 1, x0))
        let ix1 = max(0, min(n - 1, x0 + 1))
        let iy0 = max(0, min(n - 1, y0))
        let iy1 = max(0, min(n - 1, y0 + 1))

        let p00 = (iy0 * n + ix0) * 4
        let p01 = (iy0 * n + ix1) * 4
        let p10 = (iy1 * n + ix0) * 4
        let p11 = (iy1 * n + ix1) * 4

        var result: (Float, Float, Float) = (0, 0, 0)
        let invTx = 1 - tx
        let invTy = 1 - ty
        result.0 = (Float(tex[p00]) * invTx + Float(tex[p01]) * tx) * invTy
                   + (Float(tex[p10]) * invTx + Float(tex[p11]) * tx) * ty
        result.1 = (Float(tex[p00 + 1]) * invTx + Float(tex[p01 + 1]) * tx) * invTy
                   + (Float(tex[p10 + 1]) * invTx + Float(tex[p11 + 1]) * tx) * ty
        result.2 = (Float(tex[p00 + 2]) * invTx + Float(tex[p01 + 2]) * tx) * invTy
                   + (Float(tex[p10 + 2]) * invTx + Float(tex[p11 + 2]) * tx) * ty
        result.0 /= 255
        result.1 /= 255
        result.2 /= 255
        return result
    }

    /// GL MIRRORED_REPEAT。
    private static func mirrorRepeat(_ c: Float) -> Float {
        var x = abs(c)
        x = fmodf(x, 2)
        if x > 1 { x = 2 - x }
        return x
    }

    private static func fract(_ x: Float) -> Float {
        x - x.rounded(.down)
    }
}

extension URLSession {
    /// 同步 data（仅在后台队列使用；用信号量等待，超时由 request.timeoutInterval 控制）。
    fileprivate func dataSync(with request: URLRequest) -> (Data, URLResponse?) {
        var result: (Data, URLResponse?) = (Data(), nil)
        let semaphore = DispatchSemaphore(value: 0)
        dataTask(with: request) { data, response, _ in
            result = (data ?? Data(), response)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return result
    }
}
