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

    var id: String { rawValue }
}

/// 单个组件的自定义位置（相对默认位置的偏移）与缩放
struct PlayerLayoutEntry: Codable, Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    /// 组件大小缩放（1 为原始大小）
    var scale: CGFloat = 1

    init(x: CGFloat = 0, y: CGFloat = 0, scale: CGFloat = 1) {
        self.x = x
        self.y = y
        self.scale = scale
    }

    /// 兼容旧存档（老版本没有 scale 字段，缺省为 1）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1
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
        case .cover, .title, .previewLyric, .progress, .previous, .play, .next, .volume, .actions:
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
        gradientLayer.removeAnimation(forKey: "wellmusicGradStart")
        gradientLayer.removeAnimation(forKey: "wellmusicGradEnd")
        imageView.transform = .identity

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.10
        scale.duration = 14
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer.add(scale, forKey: "wellmusicBgBreathe")

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
        // 每次视图更新时立即同步frame，确保视频和封面大小完全同步
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
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
    }
}

/// 动态封面管理器：负责获取动态封面地址并缓存（每个播放器视图独立实例，互不干扰）
final class DynamicCoverManager: ObservableObject {
    @Published private(set) var coverURL: URL?
    private var currentTrackID: Int?
    private var fetchTask: Task<Void, Never>?
    private var cache: [Int: URL] = [:]

    func updateTrack(_ track: Track?) {
        let id = track?.id
        // 立即清除旧封面，避免显示上一首歌的动态封面
        currentTrackID = id
        fetchTask?.cancel()
        coverURL = nil

        guard let id = id else { return }

        // 检查缓存
        if let cached = cache[id] {
            coverURL = cached
            return
        }

        fetchTask = Task { @MainActor in
            do {
                if let urlString = try await NeteaseAPI.songDynamicCover(id: id),
                   !urlString.isEmpty,
                   urlString.hasPrefix("http"),
                   let url = URL(string: urlString) {
                    cache[id] = url
                    if currentTrackID == id {
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
