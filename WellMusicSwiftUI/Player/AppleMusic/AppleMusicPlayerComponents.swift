import SwiftUI
import UIKit
import AVKit
import CoreImage.CIFilterBuiltins

// MARK: - 全局工具

/// 秒数格式化为 m:ss
func wellamTimeString(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - 触感反馈

enum WellHaptics {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)

    static func tap() {
        lightImpact.impactOccurred()
    }

    static func medium() {
        mediumImpact.impactOccurred()
    }
}

// MARK: - 按压动效

struct GlassPressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? 0.025 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

// MARK: - 播放/暂停 morph 图标

/// 播放/暂停 morph 图标：三角播放态与双竖线暂停态共享一个固定画布，避免按钮尺寸跳动。
struct PlayPauseMorphIcon: View {
    let isPlaying: Bool
    var size: CGFloat = 22

    private var progress: CGFloat { isPlaying ? 1 : 0 }

    var body: some View {
        ZStack {
            Image(systemName: "play.fill")
                .font(.system(size: size, weight: .semibold))
                .opacity(1 - progress)
                .scaleEffect(1 - progress * 0.18)
                .offset(x: progress * 5)
            HStack(spacing: max(3, size * 0.18)) {
                RoundedRectangle(cornerRadius: max(1.5, size * 0.08), style: .continuous)
                    .frame(width: max(4, size * 0.24), height: size * 0.86)
                RoundedRectangle(cornerRadius: max(1.5, size * 0.08), style: .continuous)
                    .frame(width: max(4, size * 0.24), height: size * 0.86)
            }
            .opacity(progress)
            .scaleEffect(0.82 + progress * 0.18)
            .offset(x: (1 - progress) * -5)
        }
        .frame(width: size + 6, height: size + 6)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isPlaying)
    }
}

// MARK: - 封面图（统一走 WellImageCache：两级缓存 + 防盗链头）

struct CoverImage: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 12
    /// 封面未加载时的提示文字；nil 显示中性图标
    var emptyHint: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                WellAsyncImage(url: url) {
                    placeholderIcon
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
            if let emptyHint {
                Text(emptyHint)
                    .font(.system(size: max(11, min(size * 0.09, 15)), weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Hex 颜色

extension Color {
    /// 支持 "#RGB" / "#RGBA" / "#RRGGBB" / "#RRGGBBAA"
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 3:
            r = Double((value & 0xF00) >> 8) / 15
            g = Double((value & 0x0F0) >> 4) / 15
            b = Double(value & 0x00F) / 15
            a = 1
        case 4:
            r = Double((value & 0xF000) >> 12) / 15
            g = Double((value & 0x0F00) >> 8) / 15
            b = Double((value & 0x00F0) >> 4) / 15
            a = Double(value & 0x000F) / 15
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((value & 0xFF000000) >> 24) / 255
            g = Double((value & 0x00FF0000) >> 16) / 255
            b = Double((value & 0x0000FF00) >> 8) / 255
            a = Double(value & 0x000000FF) / 255
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - 歌词时序

enum LyricTiming {
    static let userOffsetKey = "wellmusic.lyricOffset"

    static func effectiveProgress(_ progress: Double, userOffset: Double? = nil) -> Double {
        let offset = userOffset ?? UserDefaults.standard.double(forKey: userOffsetKey)
        return max(0, progress + offset)
    }

    static func seekTime(for line: LyricLine, userOffset: Double? = nil) -> Double {
        let offset = userOffset ?? UserDefaults.standard.double(forKey: userOffsetKey)
        return max(0, line.time - offset)
    }
}

// MARK: - Apple Music 播放页布局调整

/// Apple Music 播放页实时调试组件。
enum AppleMusicLayoutPart: String, CaseIterable, Identifiable {
    case top = "顶部指示线"
    case cover = "封面"
    case title = "歌名歌手"
    case previewLyric = "预览歌词"
    case progress = "进度条"
    case previous = "上一首"
    case play = "播放按钮"
    case next = "下一首"
    case volume = "音量条"
    case actions = "底部按钮"
    /// 歌词页顶部**整行**（小封面 + 歌名歌手 + 五角星 + 三点）整体位置。
    /// ⚠️ 与 `.title`（大封面状态那行）**互相独立**，歌词页单独调不影响大封面。
    case lyricsHeader = "歌词页顶部整行"
    /// 歌词页顶部**歌名/歌手文字块**单独位置（在 `lyricsHeader` 内部再叠一层）。
    case lyricsTrackInfo = "歌词页歌名歌手"

    var id: String { rawValue }
}

/// 播放器调整面板里可调的位置分组（2026-10-13 新增）。
///
/// 与 `AppleMusicLayoutPart` 的对应关系：
/// * `.bigCover`   → 大封面整体位置（大封面状态的 `cover`）
/// * `.trackInfo`  → 歌手/歌曲信息块（大封面与歌词页头部共用同一份偏移 + 字号）
/// * `.progress`   → 进度条（复用 `AppleMusicLayoutPart.progress`）
/// * `.controls`   → 上一首/播放/下一首**整体**（控制中心调整，复用三者的共同 y）
/// * `.volume`     → 音量条
/// * `.bottomActions` → 评论区/歌词入口/播放列表（复用 `actions`）
enum PlayerAdjustGroup: String, CaseIterable, Identifiable {
    case bigCover = "大封面位置"
    case trackInfo = "歌手歌曲信息"
    case progress = "播放进度条"
    case controls = "控制中心"
    case volume = "音量条"
    case bottomActions = "底部按钮"

    var id: String { rawValue }
}

/// 单个组件的自定义位置（相对默认位置的偏移）、缩放与字号。
struct PlayerLayoutEntry: Codable, Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    /// 组件大小缩放（1 为原始大小）
    var scale: CGFloat = 1
    /// 文本字号（pt）。仅对文本类组件（歌手/歌曲信息）有意义；
    /// **0 表示「未设置」，使用默认值**（避免旧存档被强行改字号）。
    var fontSize: CGFloat = 0

    init(x: CGFloat = 0, y: CGFloat = 0, scale: CGFloat = 1, fontSize: CGFloat = 0) {
        self.x = x
        self.y = y
        self.scale = scale
        self.fontSize = fontSize
    }

    /// 兼容旧存档（老版本没有 scale / fontSize 字段）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 0
    }
}

/// Apple Music 播放页布局存储。
final class AppleMusicLayoutStore: ObservableObject {
    static let shared = AppleMusicLayoutStore()

    private static let dataKey = "wellmusic.appleMusic.layoutData"
    private let defaults = UserDefaults.standard

    @Published var entries: [String: PlayerLayoutEntry] {
        didSet { scheduleSave() }
    }

    private init() {
        if let raw = defaults.string(forKey: Self.dataKey),
           let data = raw.data(using: .utf8),
           let stored = try? JSONDecoder().decode([String: PlayerLayoutEntry].self, from: data) {
            var normalized = stored
            if normalized[AppleMusicLayoutPart.top.rawValue] == PlayerLayoutEntry() {
                normalized[AppleMusicLayoutPart.top.rawValue] = Self.defaultEntry(for: .top)
            }
            entries = normalized
            if normalized != stored {
                save(normalized)
            }
        } else {
            entries = Self.migrateLegacyEntries(from: defaults)
        }
    }

    func entry(for part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        entries[part.rawValue] ?? Self.defaultEntry(for: part)
    }

    func set(_ entry: PlayerLayoutEntry, for part: AppleMusicLayoutPart) {
        entries[part.rawValue] = entry
    }

    /// 「控制中心调整」：把上一首 / 播放 / 下一首三个组件作为一个整体设置 y。
    ///
    /// 需求（2026-10-13）：三个按钮**不分开调整**，只提供整体上下位移。
    func setControlsY(_ y: CGFloat) {
        for part in [AppleMusicLayoutPart.previous, .play, .next] {
            var entry = entry(for: part)
            entry.y = y
            entries[part.rawValue] = entry
        }
    }

    /// 读取当前「控制中心」整体的 y（三者的共同值；不一致时取播放按钮的值）。
    var controlsY: CGFloat {
        entry(for: .play).y
    }

    func reset(_ part: AppleMusicLayoutPart) {
        entries[part.rawValue] = nil
    }

    func resetAll() {
        entries = [:]
    }

    private var pendingSave: DispatchWorkItem?

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem { [weak self] in
            self?.save(snapshot)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func save(_ snapshot: [String: PlayerLayoutEntry]) {
        guard let data = try? JSONEncoder().encode(snapshot),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: Self.dataKey)
    }

    static func defaultEntry(for part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        switch part {
        case .top:
            return PlayerLayoutEntry(y: -63)
        case .cover, .title, .previewLyric, .progress, .previous, .play, .next, .volume, .actions,
             .lyricsHeader, .lyricsTrackInfo:
            return PlayerLayoutEntry()
        }
    }

    private static func migrateLegacyEntries(from defaults: UserDefaults) -> [String: PlayerLayoutEntry] {
        var migrated: [String: PlayerLayoutEntry] = [:]

        func legacyDouble(_ key: String, defaultValue: Double) -> CGFloat {
            guard defaults.object(forKey: key) != nil else { return CGFloat(defaultValue) }
            return CGFloat(defaults.double(forKey: key))
        }

        migrated[AppleMusicLayoutPart.top.rawValue] = PlayerLayoutEntry(
            y: legacyDouble("wellmusic.appleMusic.topY", defaultValue: -63)
        )
        migrated[AppleMusicLayoutPart.cover.rawValue] = PlayerLayoutEntry(
            scale: legacyDouble("wellmusic.appleMusic.coverScale", defaultValue: 1)
        )
        migrated[AppleMusicLayoutPart.title.rawValue] = PlayerLayoutEntry(
            y: legacyDouble("wellmusic.appleMusic.titleY", defaultValue: 0)
        )
        migrated[AppleMusicLayoutPart.previewLyric.rawValue] = PlayerLayoutEntry(
            y: legacyDouble("wellmusic.appleMusic.lyricY", defaultValue: 0)
        )
        let legacyControls = PlayerLayoutEntry(
            y: legacyDouble("wellmusic.appleMusic.controlsY", defaultValue: 0)
        )
        migrated[AppleMusicLayoutPart.previous.rawValue] = legacyControls
        migrated[AppleMusicLayoutPart.play.rawValue] = legacyControls
        migrated[AppleMusicLayoutPart.next.rawValue] = legacyControls
        migrated[AppleMusicLayoutPart.actions.rawValue] = PlayerLayoutEntry(
            y: legacyDouble("wellmusic.appleMusic.actionsY", defaultValue: 0)
        )
        return migrated
    }
}

/// 仅负责应用 Apple Music 组件的实时位置和大小。
struct AppleMusicLayoutTransform: ViewModifier {
    let entry: PlayerLayoutEntry

    func body(content: Content) -> some View {
        content
            .scaleEffect(entry.scale)
            .offset(x: entry.x, y: entry.y)
    }
}

// MARK: - 封面毛玻璃背景（UIKit 独立图层，不参与 SwiftUI 布局）
//
// 后台一次性高斯模糊封面图并缓存，前台只做静态显示，几乎零持续开销。
// 切歌换图使用 UIView 交叉溶解过渡，视觉平滑。

struct CoverBlurBackground: UIViewRepresentable {
    let url: URL?
    let scheme: ColorScheme

    func makeUIView(context: Context) -> CoverBlurView {
        let view = CoverBlurView()
        view.updateScheme(scheme)
        view.load(url: url)
        return view
    }

    func updateUIView(_ uiView: CoverBlurView, context: Context) {
        uiView.updateScheme(scheme)
        uiView.load(url: url)
    }
}

final class CoverBlurView: UIView {
    private let imageView = UIImageView()
    private let gradientLayer = CAGradientLayer()
    private let gradientHost = UIView()
    private let tintView = UIView()
    private var currentURL: URL?
    private static let imageCache = NSCache<NSURL, UIImage>()
    private static let blurQueue = DispatchQueue(label: "wellmusic.coverblur", qos: .utility)
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        tintView.isUserInteractionEnabled = false
        gradientHost.isUserInteractionEnabled = false

        gradientLayer.colors = [UIColor.systemGray.cgColor, UIColor.systemGray2.cgColor]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.opacity = 0.62
        gradientHost.layer.addSublayer(gradientLayer)

        addSubview(imageView)
        addSubview(gradientHost)
        addSubview(tintView)
        startBackgroundAnimations()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientHost.frame = bounds
        gradientLayer.frame = bounds
        imageView.frame = bounds
        tintView.frame = bounds
    }

    /// 背景动态效果：模糊封面缓慢呼吸缩放 + 主色渐变端点缓慢摆动。
    private func startBackgroundAnimations() {
        imageView.layer.removeAnimation(forKey: "wellmusicBgBreathe")
        imageView.layer.removeAnimation(forKey: "wellmusicBgPanX")
        imageView.layer.removeAnimation(forKey: "wellmusicBgPanY")
        gradientLayer.removeAnimation(forKey: "wellmusicGradStart")
        gradientLayer.removeAnimation(forKey: "wellmusicGradEnd")
        imageView.transform = .identity

        // 严格对齐参考源码 `WellMusicAppleMusicV2Player.tsx` 的位图流动背景：
        //   bgScale       1.1  → 1.15   20000ms  inOut(ease)  自动反向 → 等效 autoreverses
        //   bgTranslateX  -20  → +20    15000ms  inOut(ease)
        //   bgTranslateY  -15  → +15    18000ms  inOut(ease)
        // RN 用 `withRepeat(withSequence(A, B), -1, true)`：A→B→A 单程各 20s/15s/18s，
        // CABasicAnimation 的 `autoreverses = true` + 单程 duration 与之完全等价。
        // 注：RN 的 translate 是相对于原点的 ±值，这里拆成「单程半幅」以配合 autoreverses。

        // 1) 呼吸缩放：1.1 → 1.15（基准 1.1，振幅 0.05）
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = AppleMusicV2.Motion.Background.scaleFrom
        scale.toValue = AppleMusicV2.Motion.Background.scaleTo
        scale.duration = AppleMusicV2.Motion.Background.scaleDuration
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer.add(scale, forKey: "wellmusicBgBreathe")

        // 2) 横向平移：-20 → +20（振幅 20pt）
        let panX = CABasicAnimation(keyPath: "transform.translation.x")
        panX.fromValue = -AppleMusicV2.Motion.Background.translateX
        panX.toValue = AppleMusicV2.Motion.Background.translateX
        panX.duration = AppleMusicV2.Motion.Background.translateXDuration
        panX.autoreverses = true
        panX.repeatCount = .infinity
        panX.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer.add(panX, forKey: "wellmusicBgPanX")

        // 3) 纵向平移：-15 → +15（振幅 15pt）
        let panY = CABasicAnimation(keyPath: "transform.translation.y")
        panY.fromValue = -AppleMusicV2.Motion.Background.translateY
        panY.toValue = AppleMusicV2.Motion.Background.translateY
        panY.duration = AppleMusicV2.Motion.Background.translateYDuration
        panY.autoreverses = true
        panY.repeatCount = .infinity
        panY.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer.add(panY, forKey: "wellmusicBgPanY")

        // 渐变色缓慢摆动（背景基调的呼吸感，不属参考源码但保留既有观感）
        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = NSValue(cgPoint: CGPoint(x: 0.5, y: 0))
        start.toValue = NSValue(cgPoint: CGPoint(x: 0.68, y: 0))
        start.duration = 12
        start.autoreverses = true
        start.repeatCount = .infinity
        start.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.add(start, forKey: "wellmusicGradStart")

        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = NSValue(cgPoint: CGPoint(x: 0.5, y: 1))
        end.toValue = NSValue(cgPoint: CGPoint(x: 0.32, y: 1))
        end.duration = 12
        end.autoreverses = true
        end.repeatCount = .infinity
        end.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.add(end, forKey: "wellmusicGradEnd")
    }

    func updateScheme(_ scheme: ColorScheme) {
        tintView.backgroundColor = scheme == .dark
            ? UIColor.black.withAlphaComponent(0.30)
            : UIColor.white.withAlphaComponent(0.10)
    }

    func load(url: URL?) {
        guard let url else {
            imageView.image = nil
            return
        }
        if currentURL == url { return }
        currentURL = url

        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            setImage(cached, animated: false)
            applyGradientIfNeeded(for: url)
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let source = UIImage(data: data) else { return }
            Self.blurQueue.async {
                let blurred = Self.makeBlurredImage(source)
                let colors = Self.extractGradientColors(from: source)
                if let blurred {
                    Self.imageCache.setObject(blurred, forKey: url as NSURL)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentURL == url else { return }
                    if let blurred { self.setImage(blurred, animated: true) }
                    self.applyGradient(colors)
                }
            }
        }.resume()
    }

    private func applyGradient(_ colors: (top: UIColor, bottom: UIColor)) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        gradientLayer.colors = [colors.top.cgColor, colors.bottom.cgColor]
        CATransaction.commit()
    }

    private func applyGradientIfNeeded(for url: URL) {
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            let colors = Self.extractGradientColors(from: cached)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            gradientLayer.colors = [colors.top.cgColor, colors.bottom.cgColor]
            CATransaction.commit()
        }
    }

    private static func extractGradientColors(from image: UIImage) -> (top: UIColor, bottom: UIColor) {
        let sample = image.preparingThumbnail(of: CGSize(width: 200, height: 200)) ?? image
        let top = areaAverage(of: sample, in: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
            ?? UIColor.systemGray
        let bottom = areaAverage(of: sample, in: CGRect(x: 0, y: 0, width: 1, height: 0.5))
            ?? UIColor.systemGray2
        return (top.lightened(0.28), bottom.darkened(0.48))
    }

    private static func areaAverage(of image: UIImage, in normalizedRect: CGRect) -> UIColor? {
        guard let ci = CIImage(image: image) else { return nil }
        let extent = ci.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let region = CGRect(
            x: extent.minX + extent.width * normalizedRect.minX,
            y: extent.minY + extent.height * normalizedRect.minY,
            width: extent.width * normalizedRect.width,
            height: extent.height * normalizedRect.height
        )
        let filter = CIFilter.areaAverage()
        filter.inputImage = ci
        filter.extent = region
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    private static func makeBlurredImage(_ source: UIImage) -> UIImage? {
        let target = source.preparingThumbnail(of: CGSize(width: 480, height: 480)) ?? source
        guard let input = CIImage(image: target) else { return target }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input
        filter.radius = 36
        guard let output = filter.outputImage else { return target }
        let extent = output.extent
        guard extent.width > 0, extent.height > 0,
              let cg = ciContext.createCGImage(output, from: extent) else { return target }
        return UIImage(cgImage: cg)
    }

    private func setImage(_ image: UIImage, animated: Bool) {
        guard animated, imageView.image != nil else {
            imageView.image = image
            startBackgroundAnimations()
            return
        }
        UIView.transition(
            with: imageView,
            duration: 0.4,
            options: [.transitionCrossDissolve, .beginFromCurrentState]
        ) {
            self.imageView.image = image
        } completion: { _ in
            self.startBackgroundAnimations()
        }
    }
}

private extension UIColor {
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let a = min(max(amount, 0), 1)
        return UIColor(
            red: r1 * (1 - a) + r2 * a,
            green: g1 * (1 - a) + g2 * a,
            blue: b1 * (1 - a) + b2 * a,
            alpha: 1
        )
    }

    func lightened(_ amount: CGFloat) -> UIColor { mixed(with: .white, amount: amount) }
    func darkened(_ amount: CGFloat) -> UIColor { mixed(with: .black, amount: amount) }
}

// MARK: - 动态封面视频播放器

/// 循环播放静音视频，用于网易云动态封面（始终自动播放，不依赖音乐播放状态）
struct DynamicCoverPlayer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .clear
        view.clipsToBounds = true

        // 使用 AVURLAsset 添加 Referer header，网易云视频需要验证来源
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "Referer": "https://music.163.com/",
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
            ]
        ])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer(playerItem: playerItem)
        player.isMuted = true

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = true // 视频加载完成前隐藏，避免黑色背景遮住封面
        playerLayer.masksToBounds = true // 确保视频被正确裁剪，不会超出封面范围
        view.playerLayer = playerLayer
        view.layer.addSublayer(playerLayer)

        context.coordinator.player = player
        context.coordinator.playerLayer = playerLayer
        context.coordinator.containerView = view

        // 使用AVPlayerLooper实现可靠的无限循环播放
        let looper = AVPlayerLooper(player: player, templateItem: playerItem)
        context.coordinator.looper = looper

        // 视频加载完成后标记视图为ready，触发layoutSubviews来显示视频
        context.coordinator.statusObserver = playerItem.observe(\.status, options: [.new]) { item, _ in
            DispatchQueue.main.async {
                if item.status == .readyToPlay {
                    view.isVideoReady = true
                    view.setNeedsLayout()
                    view.layoutIfNeeded()
                    player.play()
                }
            }
        }

        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        // ⚠️ 2026-10-14 性能修正：只有**尺寸真的变了**才强制同步布局。
        //
        // `updateUIView` 会随父视图每次重算被调用 —— 播放页下滑关闭拖拽时就是
        // **每帧**一次；旧实现无条件 `setNeedsLayout() + layoutIfNeeded()`，
        // 等于每帧强制跑一次同步布局，是「下滑不跟手 / 掉帧」的来源之一。
        // 拖拽时视图只是被 `.offset` 平移，bounds 根本不变，这次布局纯属浪费。
        if uiView.bounds.size != context.coordinator.lastLaidOutSize {
            context.coordinator.lastLaidOutSize = uiView.bounds.size
            uiView.setNeedsLayout()
            uiView.layoutIfNeeded()
        }
        // 确保视频始终在播放
        if context.coordinator.player?.timeControlStatus != .playing {
            context.coordinator.player?.play()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 容器视图，管理视频加载状态和playerLayer布局
    class PlayerContainerView: UIView {
        var playerLayer: AVPlayerLayer?
        var isVideoReady = false

        override func layoutSubviews() {
            super.layoutSubviews()
            // 用CATransaction禁用隐式动画，确保playerLayer的frame立即同步UIView的bounds
            // 否则SwiftUI动画期间CALayer frame和UIView bounds不同步，导致显示异常
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer?.frame = bounds
            CATransaction.commit()
            // 视频加载完成后显示
            if isVideoReady {
                playerLayer?.isHidden = false
            }
        }
    }

    class Coordinator: NSObject {
        var player: AVQueuePlayer?
        var playerLayer: AVPlayerLayer?
        var containerView: PlayerContainerView?
        var looper: AVPlayerLooper?
        var statusObserver: NSKeyValueObservation?
        /// 上一次强制同步布局时的尺寸（见 `updateUIView`：尺寸没变就不再强制布局）
        var lastLaidOutSize: CGSize = .zero
    }
}

/// 动态封面管理器：负责获取动态封面地址并缓存（每个播放器视图独立实例，互不干扰）
final class DynamicCoverManager: ObservableObject {
    @Published private(set) var coverURL: URL?
    private var currentTrackID: String?
    private var fetchTask: Task<Void, Never>?
    private var cache: [String: URL] = [:]

    /// 按当前曲目更新动态封面。
    ///
    /// ⚠️ 两条硬约束：
    /// 1. 只对**网易云直连**的曲目请求（`sourcePlatform == "netease"`）——
    ///    eapi 接口按网易云歌曲 id 查询，别的平台的 id 传进去只会白打请求；
    /// 2. 必须用 `platformSongId`（网易云真实歌曲 id）—— `Track.id` 是
    ///    keyOf 的稳定哈希，拿它查询永远查不到。
    func updateTrack(_ track: Track?) {
        // 立即清除旧封面，避免显示上一首歌的动态封面
        let songId = track?.platformSongId
        let isNetease = track?.sourcePlatform == "netease"
        let key: String? = (isNetease && !(songId ?? "").isEmpty) ? songId : nil
        currentTrackID = key
        fetchTask?.cancel()
        coverURL = nil

        guard let key = key else { return }

        // 检查缓存
        if let cached = cache[key] {
            coverURL = cached
            return
        }

        fetchTask = Task { @MainActor in
            do {
                if let urlString = try await NeteaseAPI.songDynamicCover(songId: key),
                   !urlString.isEmpty,
                   urlString.hasPrefix("http"),
                   let url = URL(string: urlString) {
                    cache[key] = url
                    if currentTrackID == key {
                        coverURL = url
                    }
                }
            } catch {
                // 动态封面获取失败静默处理，不是所有歌曲都有动态封面
            }
        }
    }

    func clear() {
        fetchTask?.cancel()
        currentTrackID = nil
        coverURL = nil
    }
}

// MARK: - 歌词偏移精细调节

/// 歌词偏移弹窗（对应参考源码 `lyricOffset` 面板）。
///
/// 语义与播放器 `moreMenu` 里的「歌词时间微调」保持一致：
/// - 正值 = 歌词高亮**提前**（歌声还没到，歌词已高亮）
/// - 负值 = 歌词高亮**推迟**
///
/// 写入两个位置：
/// - `appState.lyricOffset`：驱动非 AMLL 歌词页与 `LyricTiming` 的实时高亮
/// - `settings.lyricOffset`：驱动 AMLL Web 歌词页（读 `wellmusic.lyricOffset`）
///
/// 范围 ±5 秒、步进 0.1 秒（滑块连续、按钮微调）。
struct LyricOffsetSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsManager
    /// 只读一个数：实测输出延迟（显示用，不订阅它的其它高频字段）
    @EnvironmentObject private var player: PlayerService

    @Environment(\.dismiss) private var dismiss

    /// 下限 / 上限 / 最小步进（秒）
    private static let range: ClosedRange<Double> = -5.0...5.0
    private static let step: Double = 0.1
    /// 精调步进（秒）：10ms。用于把蓝牙 / 无损输出的残余偏差压到几乎听不出。
    private static let fineStep: Double = 0.01

    /// 本地草稿值：拖动过程中不反复写 UserDefaults，松手才落盘
    @State private var draft: Double = 0
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                valueDisplay

                slider

                presetRow

                fineTuneRow

                // 实测输出延迟：既让用户看到「自动补偿」补了多少，也是验证设备链路的手段
                // （蓝牙 A2DP 通常 150–250ms，有线/扬声器 <30ms）。
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 11))
                    Text("当前输出延迟 \(Int((player.outputLatency * 1000).rounded())) ms · 已自动补偿")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)

                // 端到端同步判据：歌词页时钟 vs 播放器位置。Δ≈0 而听着不齐 → 内核问题；
                // Δ 大 → 时钟链路问题。播放中打开本面板即可读数。
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let s = LyricSyncProbe.shared.sample
                    let fresh = Date().timeIntervalSinceReferenceDate - s.timestamp < 2
                    Group {
                        if !fresh {
                            Text("同步判据：播放中自动采样…")
                        } else if s.awaitingLanding {
                            Text("同步判据：seek 落地中（时钟已冻结，等音频跟上）")
                        } else {
                            Text(String(format: "同步判据 Δ = %+.0f ms（歌词页相对播放器）", s.deltaMs))
                        }
                    }
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                }

                Text("正值表示歌词提前，负值表示歌词推迟。\n蓝牙 / 有线的输出延迟已自动补偿，这里只需微调残余偏差。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("歌词偏移")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        apply(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = clamped(appState.lyricOffset)
        }
    }

    // MARK: - 子视图

    /// 当前值：大字 + 方向说明
    private var valueDisplay: some View {
        VStack(spacing: 6) {
            Text(formatted(draft))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            Text(directionText(draft))
                .font(.system(size: 14))
                .foregroundStyle(draft == 0 ? Color.secondary : Color.accentColor)
        }
        .padding(.top, 8)
    }

    private var slider: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { draft },
                    set: { draft = clamped($0) }
                ),
                in: Self.range,
                step: Self.step,
                onEditingChanged: { editing in
                    // 松手时落盘，拖动中只改草稿
                    if !editing { apply(draft) }
                }
            )
            .tint(.accentColor)
            .padding(.horizontal, 24)

            HStack {
                Text("-5.0s")
                Spacer()
                Text("0")
                Spacer()
                Text("+5.0s")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 28)
        }
    }

    /// 常用预设（与播放器菜单里的档位一致）
    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach([-1.0, -0.5, 0, 0.5, 1.0], id: \.self) { value in
                Button {
                    draft = value
                    apply(value)
                } label: {
                    Text(value == 0 ? "复位" : formatted(value))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Swift.abs(draft - value) < 0.01
                                      ? Color.accentColor.opacity(0.18)
                                      : Color(uiColor: .secondarySystemGroupedBackground))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    /// 微调：先粗后细。
    ///
    /// 只有 0.1s 一档对「只差一点点」太粗 —— 蓝牙耳机 / 无损输出的残余延迟
    /// 常常只有几十毫秒，用 0.1s 去凑只会一直过冲。所以再给一档 10ms。
    private var fineTuneRow: some View {
        VStack(spacing: 10) {
            fineTuneLine(title: "粗调 0.1s", delta: Self.step)
            fineTuneLine(title: "精调 0.01s", delta: Self.fineStep)
        }
        .padding(.horizontal, 20)
    }

    private func fineTuneLine(title: String, delta: Double) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            fineButton(systemName: "minus", delta: -delta, label: "\(title) 减少")
            fineButton(systemName: "plus", delta: delta, label: "\(title) 增加")
        }
    }

    private func fineButton(systemName: String, delta: Double, label: String) -> some View {
        Button {
            let next = clamped(draft + delta)
            draft = next
            apply(next)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - 逻辑

    /// 双写：AppState 驱动原生歌词页，SettingsManager 驱动 AMLL 网页歌词
    private func apply(_ value: Double) {
        let next = clamped(value)
        appState.lyricOffset = next
        settings.lyricOffset = next
    }

    private func clamped(_ value: Double) -> Double {
        // 对齐到 0.1 秒，避免浮点误差累积
        let rounded = (value * 10).rounded() / 10
        return min(max(rounded, Self.range.lowerBound), Self.range.upperBound)
    }

    private func formatted(_ value: Double) -> String {
        // 两位小数：精调步进是 10ms，一位小数看不出变化
        String(format: "%+.2f s", value)
    }

    private func directionText(_ value: Double) -> String {
        if value == 0 { return "无偏移" }
        return value > 0 ? "歌词提前" : "歌词推迟"
    }
}

// =====================================================================================
// MARK: - 播放器 UI 与交互组件
//
// 范围限定为「视觉 + 交互」。两个承载**行为**的部件一律使用本项目自身实现：
//   * `PlayerSeekBar`  —— 时间源走 `PlayerCore` 的拖拽仲裁
//                             （`beginScrubbing` / `updateScrubbing` / `endScrubbing`）。
//   * AMLL 歌词同步        —— 由 `AMLLWebLyricsView` + `hardCalibrate` 通道负责。
// =====================================================================================

// MARK: - 封面 / 文本锚点

/// 收集歌词行在视口坐标系内的中线位置，用于判定「当前聚焦行」。
struct LyricLineCenterKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 大封面与歌词页迷你封面之间做插值动画时，用来指认「大 / 小」两个落点。
enum CoverArtAnchor: Hashable {
    case expanded
    case compact
}

/// 收集大封面与迷你封面在各自坐标系内的实际位置。
struct AppleMusicArtworkFrameKey: PreferenceKey {
    static var defaultValue: [CoverArtAnchor: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [CoverArtAnchor: Anchor<CGRect>],
        nextValue: () -> [CoverArtAnchor: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 歌名 / 歌手文本在大封面页与歌词页两处的落点。
enum HeaderTextAnchor: Hashable {
    case titleExpanded
    case titleCompact
    case artistExpanded
    case artistCompact
}

struct AppleMusicTextFrameKey: PreferenceKey {
    static var defaultValue: [HeaderTextAnchor: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [HeaderTextAnchor: Anchor<CGRect>],
        nextValue: () -> [HeaderTextAnchor: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 竖屏排版常量。
enum PlayerLayoutMetrics {
    /// 顶部留白
    static let headerTopSpacing: CGFloat = 20
}

// MARK: - 进度条

/// Apple Music 风格的进度条。
///
/// **注意（关键设计）**：拖拽状态一律由 `PlayerCore` 仲裁，本视图不持有
/// `scrubbing` / `isSeeking` 这类本地时间状态。若改用「本地猜测位置是否已对上」
/// （例如 `abs(newProgress - scrubValue) < 0.3`），会在无损 / Hi-Res 文件上
/// 长时间不满足，从而把 `isSeeking` 卡在 true、进度条停在拖拽值不动。
///
/// 这里改为：
///   * onChanged → `PlayerCore.beginScrubbing()` / `updateScrubbing(_:)`
///   * onEnded   → `PlayerCore.endScrubbing(_:)`，由它在超时 / 位置对齐后自行收尾
/// 显示值则直接取 `PlayerCore.displayTime`，拖拽期间它就是 scrubTime。
struct PlayerSeekBar: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var core = PlayerCore.shared
    /// 是否显示拖拽气泡
    @State private var showBubble = false

    private var totalDuration: Double {
        max(max(player.duration, player.currentTrack?.duration ?? 0), 1)
    }

    /// 当前显示时间。
    ///
    /// ⚠️ 这里**直接向 AVPlayer 取位置**（`core.playerPosition`），**不用**
    /// `PlayerCore.currentTime`。这正是「无损以上感觉不跟手」的一条真实原因：
    /// `currentTime` 由 `addPeriodicTimeObserver` 维护，而传入的 0.05s 只是
    /// 「**至少**这么频繁」—— 无损 / Hi-Res 大文件上解码压力大，实际回调会被明显拉长，
    /// 进度条就会一格一格地跳（标准音质下看不出来）。
    /// 拖动中仍用 `scrubTime`（手指位置）。
    private var displayTime: Double {
        let raw = core.isScrubbing ? core.scrubTime : core.playerPosition
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), totalDuration)
    }

    var body: some View {
        // 逐帧（30fps）重绘：位置来源已经换成即时读值，但 SwiftUI 总得有个东西触发重绘。
        // 只在「在播放 or 正在拖动」时跑，暂停时停摆，不白耗电。
        //
        // 为什么不靠 `@Published currentTime` 触发：它的节奏就是上面说的那个被拉长的周期回调，
        // 无损文件上会让进度条一顿一顿。原版（Sollin）用的是逐帧 `_uiTicker`，同一个道理。
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: !player.isPlaying && !core.isScrubbing)) { _ in
            barBody
        }
    }

    @ViewBuilder
    private var barBody: some View {
        let total = totalDuration
        let time = displayTime

        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let progress = CGFloat(min(max(time / total, 0), 1))
                let filledWidth = width * progress
                let trackH: CGFloat = showBubble ? 15 : 7
                // 气泡水平方向夹在轨道内，避免贴边溢出
                let bubbleX = max(-width / 2 + 31, min(width / 2 - 31, filledWidth - width / 2))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: trackH)

                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: max(0, filledWidth), height: trackH)
                }
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = min(max(value.location.x / width, 0), 1)
                            let target = Double(ratio) * total
                            if !showBubble {
                                showBubble = true
                                // 以**当前播放位置**进入拖拽态：若传手指位置，进度条会在
                                // 按下瞬间从原位跳到手指处，视觉上是断的。
                                core.beginScrubbing(to: min(max(core.displayTime, 0), total))
                            }
                            core.updateScrubbing(to: target)
                        }
                        .onEnded { value in
                            let ratio = min(max(value.location.x / width, 0), 1)
                            let target = Double(ratio) * total
                            core.updateScrubbing(to: target)
                            core.endScrubbing(to: target)
                            showBubble = false
                        }
                )
                .overlay(alignment: .top) {
                    if showBubble {
                        Text(wellamTimeString(time))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: Capsule())
                            .offset(x: bubbleX, y: -30)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
            .frame(height: 30)

            // 时间行：左「当前时间」/ 右「-剩余时间」
            // （用户明确：播放器界面**不要**显示音质徽章，去掉中间那栏）
            HStack(spacing: 0) {
                Text(wellamTimeString(time))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("-" + wellamTimeString(max(0, total - time)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: 420)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: showBubble)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: core.isScrubbing)
    }
}

// MARK: - 收藏按钮（叶子视图）

/// 播放页的收藏按钮（**五角星**，需求 13）。
///
/// **为什么要单独抽成一个视图**：收藏状态只驱动这一个图标，但它来源于
/// `AccountStore`。如果把 `@ObservedObject AccountStore.shared` 挂在
/// `AppleMusicPlayerView` 顶层，任何收藏变化都会让**整页**重算 —— 页里有
/// `WKWebView`（474KB 页面 + WebGL 流动背景），一次全量重算就要重新测量
/// `UIScreen`、遍历 window scene、并向下发一轮 `evaluateJavaScript`。
/// 抽成叶子后，重算范围收敛到这一个按钮，开销可忽略。
struct PlayerLikeButton: View {
    let track: Track?
    var primaryColor: Color = .white
    var accentColor: Color = .red

    /// 只订阅收藏集合，不订阅整个 `AccountStore` 的其它状态。
    @ObservedObject private var account = AccountStore.shared

    private var isLiked: Bool {
        guard let track else { return false }
        return account.isLiked(track: track)
    }

    var body: some View {
        Button {
            guard let track else { return }
            Task { await AccountStore.shared.toggleLike(trackID: track.id, track: track) }
        } label: {
            // 用户要求：五角星**收藏后保持白色**，不要变红。
            Image(systemName: isLiked ? "star.fill" : "star")
                .font(.system(size: ScreenAdapter.h(17), weight: .semibold))
                .foregroundStyle(isLiked ? primaryColor : primaryColor.opacity(0.78))
                .frame(width: ScreenAdapter.h(30), height: ScreenAdapter.h(30))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 音量条

/// 常驻横向音量条：左右为喇叭图标，中间可拖拽。
struct PlayerVolumeControl: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16, height: 20)

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let fraction = isDragging ? dragValue : Double(player.volume)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 7)
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: width * CGFloat(min(max(fraction, 0), 1)), height: 7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let val = Double(min(max(value.location.x / width, 0), 1))
                            dragValue = val
                            player.volume = Float(val)
                        }
                        .onEnded { value in
                            let val = Double(min(max(value.location.x / width, 0), 1))
                            dragValue = val
                            player.volume = Float(val)
                            isDragging = false
                        }
                )
            }
            .frame(height: 20)

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16, height: 20)
        }
        .frame(height: 20)
    }
}

// MARK: - 迷你歌词预览

/// 大封面页上的两行歌词预览，点击进入歌词页。
struct MiniLyricsPreview: View {
    let action: () -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor

    private var currentLines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = lyricsCursor.activeIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (_, current, next) = currentLines
        Button(action: action) {
            VStack(spacing: 8) {
                if current == nil && next == nil {
                    Text("暂无歌词")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.54))
                } else {
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current?.id)
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Text(line?.text.isEmpty == false ? line!.text : " ")
            .font(.system(size: emphasized ? 17 : 14, weight: emphasized ? .bold : .medium))
            .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .id(line?.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - 播放队列

struct PlayQueueList: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss

    private var playbackModeIcon: String {
        if player.shuffleEnabled { return "shuffle" }
        switch player.repeatMode {
        case .one: return "repeat.1"
        case .all: return "repeat"
        case .off: return "repeat"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                Text("播放队列")
                    .font(.system(size: 17, weight: .bold))
                Text("\(player.queue.count) 首")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    player.cyclePlaybackMode()
                } label: {
                    Image(systemName: playbackModeIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(player.shuffleEnabled ? Color.accentColor : .primary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    player.clearQueue()
                } label: {
                    Text("清空")
                        .font(.system(size: 15, weight: .medium))
                }
                .disabled(player.queue.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if player.queue.isEmpty {
                Spacer()
                EmptyStateView(icon: "music.note.list", title: "播放队列为空")
                Spacer()
            } else {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                        row(track, index: index)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                    .onDelete { offsets in
                        // 从大到小删除，避免索引漂移
                        for index in offsets.sorted(by: >) where player.queue.indices.contains(index) {
                            player.removeFromQueue(at: index)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func row(_ track: Track, index: Int) -> some View {
        let isCurrent = index == player.currentIndex
        HStack(spacing: 12) {
            CoverImage(url: URL(string: track.album.picUrl ?? ""), size: 46, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(track.artistNames)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(Formatters.duration(track.duration))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            player.play(tracks: player.queue, source: .none, startAt: track)
            dismiss()
        }
    }
}

// MARK: - Sheet 辅助

/// 评论区 sheet：iOS 16.4+ 使用半屏 detents，背景交给 `CommentsView` 自绘。
struct PlayerSheetDetents: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 16.4, *) {
                content
                    .presentationDetents([.medium, .large])
                    .presentationBackground(.white)
            } else {
                content
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

extension View {
    /// 在不支持 detents 的系统上退化为普通 sheet。
    @ViewBuilder
    func presentationDetentsSafe() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium])
        } else {
            self
        }
    }
}

// MARK: - 音量浮层

/// 竖直音量浮层（Apple Music 播放器的音量按钮弹出样式）。
struct VolumePopover: View {
    @EnvironmentObject private var player: PlayerService
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 16, weight: .medium))

            GeometryReader { geo in
                let height = max(geo.size.height, 1)
                let fraction = min(max(CGFloat(player.volume), 0), 1)
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.82))
                        .frame(height: height * fraction)
                }
                .frame(width: isDragging ? 12 : 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            updateVolume(at: value.location.y, height: height)
                        }
                        .onEnded { value in
                            updateVolume(at: value.location.y, height: height)
                            isDragging = false
                        }
                )
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
            }
            .frame(width: 32, height: 132)
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            .accessibilityAdjustableAction(adjustVolume)

            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottom) {
            PopoverArrow()
                .fill(.white.opacity(0.18))
                .frame(width: 16, height: 8)
                .offset(y: 8)
        }
    }

    private func updateVolume(at location: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        player.volume = Float(min(max(1 - location / height, 0), 1))
    }

    private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
        let step: Float = 0.05
        switch direction {
        case .increment: player.volume = min(player.volume + step, 1)
        case .decrement: player.volume = max(player.volume - step, 0)
        @unknown default: break
        }
    }
}

/// 浮层底部的小三角。
struct PopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

// MARK: - 播放器样式选择

struct PlaybackModeSheet: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss

    /// 可选模式（已排除停用的经典模式）
    private let availableModes: [NowPlayingMode] = [.appleMusic, .immersive, .immersiveV2, .vinyl, .minimal]

    var body: some View {
        NavigationStack {
            List {
                ForEach(availableModes) { mode in
                    Button {
                        dismiss()
                        // 延迟切换，确保 sheet 先关闭再重建播放器视图
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            settings.nowPlayingMode = mode
                        }
                    } label: {
                        HStack {
                            Text(mode.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if settings.nowPlayingMode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("播放器样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetentsSafe()
    }
}

// MARK: - 音质徽章（进度条中央）

/// 进度条时间行中央的音质徽章（需求 18）。
///
/// 对齐 RN 版 `WellMusicAppleMusicV2Player` 的 `qualityBadge`：
/// 波形图标 + 当前音质简称，胶囊底。点击暂不展开（音质切换在设置页的
/// 「播放音质」弹窗里），这里只做**状态显示**。
struct QualityBadgeView: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .medium))
            Text(appState.audioQuality.badgeText)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }
}
