import Foundation
import SwiftUI
import UIKit
import Combine

// MARK: - LyricsAnnotation
enum LyricsAnnotation: String, Codable {
    case off
    case romaji
}

// MARK: - AppleMusicBackgroundMode
enum AppleMusicBackgroundMode: String, Codable, CaseIterable {
    case gradient
    case coverBlur
    case dynamicCover
    case dark
}

// MARK: - WellTabBarStyle
/// 底部栏样式
enum WellTabBarStyle: String, CaseIterable, Identifiable {
    case `default`    // 默认毛玻璃
    case liquidGlass  // 液态玻璃

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "默认毛玻璃"
        case .liquidGlass: return "液态玻璃"
        }
    }
}

// MARK: - WellGlassPreset
/// 液态玻璃预设
enum WellGlassPreset: String, CaseIterable, Identifiable {
    case custom      // 自定义
    case white       // 白色高模糊
    case lightBlue   // 浅蓝色（原库 regular 浅色模式）
    case darkBlue    // 深蓝色（原库 regular 深色模式）
    case lens        // 透镜（通透高色散）
    case thumb       // 缩略图（近透明淡冷色）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .custom: return "自定义"
        case .white: return "白色"
        case .lightBlue: return "浅蓝"
        case .darkBlue: return "深蓝"
        case .lens: return "透镜"
        case .thumb: return "透明"
        }
    }

    /// 预设对应的配置
    var config: WellGlassConfig {
        switch self {
        case .custom: return .default
        case .white:
            return WellGlassConfig(tintOpacity: 0.45, blurRadius: 0.6, glassThickness: 10, refractiveIndex: 1.5, dispersionStrength: 5, tintRed: 1.0, tintGreen: 1.0, tintBlue: 1.0)
        case .lightBlue:
            // 原库 regular 浅色模式：RGB(0.902, 0.951, 1.0)
            return WellGlassConfig(tintOpacity: 0.8, blurRadius: 0.3, glassThickness: 10, refractiveIndex: 1.5, dispersionStrength: 5, tintRed: 0.902, tintGreen: 0.951, tintBlue: 1.0)
        case .darkBlue:
            // 原库 regular 深色模式：RGB(0, 0.05, 0.1)
            return WellGlassConfig(tintOpacity: 0.8, blurRadius: 0.3, glassThickness: 10, refractiveIndex: 1.5, dispersionStrength: 5, tintRed: 0, tintGreen: 0.05, tintBlue: 0.1)
        case .lens:
            return WellGlassConfig(tintOpacity: 0, blurRadius: 0, glassThickness: 6, refractiveIndex: 1.1, dispersionStrength: 15, tintRed: 1.0, tintGreen: 1.0, tintBlue: 1.0)
        case .thumb:
            return WellGlassConfig(tintOpacity: 0.15, blurRadius: 0, glassThickness: 10, refractiveIndex: 1.11, dispersionStrength: 5, tintRed: 1.0, tintGreen: 1.0, tintBlue: 1.0)
        }
    }
}

// MARK: - WellGlassConfig
/// 液态玻璃自定义配置
struct WellGlassConfig: Codable, Equatable, Hashable {
    /// 色调透明度 0-1
    var tintOpacity: Double = 0.45
    /// 背景模糊半径 0-1
    var blurRadius: Double = 0.6
    /// 玻璃厚度 0-20
    var glassThickness: Double = 10
    /// 折射率 1.0-2.0
    var refractiveIndex: Double = 1.5
    /// 色散强度 0-30
    var dispersionStrength: Double = 5
    /// 渲染帧率 30/60/90/120
    var preferredFramesPerSecond: Int = 40
    /// 色调颜色 R 0-1
    var tintRed: Double = 1.0
    /// 色调颜色 G 0-1
    var tintGreen: Double = 1.0
    /// 色调颜色 B 0-1
    var tintBlue: Double = 1.0

    static let `default` = WellGlassConfig()

    #if os(iOS)
    /// 转换成 WellGlass 配置
    var toWellGlass: WellGlass {
        WellGlass(
            shaderUniforms: .init(
                glassThickness: Float(glassThickness),
                refractiveIndex: Float(refractiveIndex),
                dispersionStrength: Float(dispersionStrength),
                fresnelDistanceRange: 70,
                fresnelIntensity: 0,
                fresnelEdgeSharpness: 0,
                glareDistanceRange: 30,
                glareAngleConvergence: 0.1,
                glareOppositeSideBias: 1,
                glareIntensity: 0.1,
                glareEdgeSharpness: -0.15,
                glareDirectionOffset: -.pi / 4
            ),
            backgroundTextureSizeCoefficient: 1,
            backgroundTextureScaleCoefficient: 0.2,
            backgroundTextureBlurRadius: blurRadius,
            tintColor: UIColor(red: CGFloat(tintRed), green: CGFloat(tintGreen), blue: CGFloat(tintBlue), alpha: CGFloat(tintOpacity))
        )
    }
    #endif
}

// MARK: - SettingsManager
/// 桥接 AppState + UserDefaults，满足 AppleMusicPlayerView 对 SettingsManager 的依赖契约。
@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    // MARK: - Now Playing Mode

    @AppStorage("wellmusic.nowPlayingMode") var nowPlayingMode: NowPlayingMode = .appleMusic

    // MARK: - 底部栏样式

    /// 底部栏样式（默认毛玻璃 / 液态玻璃）
    @AppStorage("wellmusic.tabBarStyle") var tabBarStyle: WellTabBarStyle = .default

    /// 液态玻璃预设
    @AppStorage("wellmusic.liquidGlassPreset") var liquidGlassPreset: WellGlassPreset = .custom

    /// 液态玻璃自定义配置（用户调节后的参数，切换预设不覆盖）
    @Published var customLiquidGlassConfig: WellGlassConfig {
        didSet {
            if let data = try? JSONEncoder().encode(customLiquidGlassConfig) {
                UserDefaults.standard.set(data, forKey: "wellmusic.customLiquidGlassConfig")
            }
        }
    }

    /// 液态玻璃当前生效配置（自定义预设取自定义值，否则取预设默认值）
    var liquidGlassConfig: WellGlassConfig {
        liquidGlassPreset == .custom ? customLiquidGlassConfig : liquidGlassPreset.config
    }

    // MARK: - Lyrics

    /// 歌词偏移（秒），范围 -10...10，步长 0.1
    @AppStorage("wellmusic.lyricOffset") var lyricOffset: Double = 0

    @AppStorage("wellmusic.lyric.fontSize") var lyricFontSize: Double = 20
    @AppStorage("wellmusic.lyric.lineSpacing") var lyricLineSpacing: Double = 8
    @AppStorage("wellmusic.lyric.translation") var showLyricsTranslation: Bool = true
    @AppStorage("wellmusic.lyric.glowLevel") var lyricGlowLevel: Double = 0

    /// 歌词注音显示：off / romaji
    @AppStorage("wellmusic.lyric.annotation") var lyricsAnnotation: LyricsAnnotation = .off

    // MARK: - Apple Music 专属

    @AppStorage("wellmusic.appleMusic.showVolume") var appleMusicShowVolume: Bool = true
    @AppStorage("wellmusic.appleMusic.showLyricPreview") var appleMusicShowLyricPreview: Bool = true
    @AppStorage("wellmusic.appleMusic.useAMLL") var appleMusicUseAMLL: Bool = true

    @AppStorage("wellmusic.appleMusic.primaryHex") var appleMusicPrimaryHex: String = ""
    @AppStorage("wellmusic.appleMusic.secondaryHex") var appleMusicSecondaryHex: String = ""
    @AppStorage("wellmusic.appleMusic.accentHex") var appleMusicAccentHex: String = ""
    @AppStorage("wellmusic.appleMusic.volumeHex") var appleMusicVolumeHex: String = ""

    @AppStorage("wellmusic.appleMusic.controlsHeight") var appleMusicControlsHeight: Double = 1.0

    /// AMLL 字体大小（Apple Music 模式下）
    @AppStorage("wellmusic.appleMusic.amllFontSize") var appleMusicAmllFontSize: Double = 24
    /// AMLL 字重（Apple Music 模式下）
    @AppStorage("wellmusic.appleMusic.amllFontWeight") var appleMusicAmllFontWeight: Int = 600

    /// AMLL 字体大小（其他模式下）
    @AppStorage("wellmusic.amllFontSize") var amllFontSize: Double = 24
    /// AMLL 字重（其他模式下）
    @AppStorage("wellmusic.amllFontWeight") var amllFontWeight: Int = 600

    /// AMLL 上边距比例
    @AppStorage("wellmusic.appleMusic.amllLyricTop") var appleMusicAmllLyricTop: Double = 0.38
    /// AMLL 下边距比例
    @AppStorage("wellmusic.appleMusic.amllLyricBottom") var appleMusicAmllLyricBottom: Double = 0.08
    /// AMLL 水平边距
    @AppStorage("wellmusic.appleMusic.amllLyricHorizontal") var appleMusicAmllLyricHorizontal: Double = 24

    /// 背景模式
    @AppStorage("wellmusic.appleMusic.backgroundMode") var appleMusicBackgroundMode: AppleMusicBackgroundMode = .gradient

    /// 是否启用动态封面
    @AppStorage("wellmusic.appleMusic.dynamicCoverEnabled") var dynamicCoverEnabled: Bool = true

    /// 控件是否使用封面颜色
    @AppStorage("wellmusic.player.controlsUseCoverColor") var controlsUseCoverColor: Bool = true

    // MARK: - Player

    @AppStorage("wellmusic.showSongVIPBadge") var showSongVIPBadge: Bool = false

    @AppStorage("wellmusic.player.autoSkipOnFailure") var autoSkipOnFailure: Bool = true

    @AppStorage("wellmusic.player.swipeSwitchSong") var swipeSwitchSong: Bool = true

    @AppStorage("wellmusic.player.breath") var breathEffect: Bool = true

    @AppStorage("wellmusic.player.progressBarStyle") var progressBarStyle: String = "appleMusic"

    /// 无损/高音质
    @AppStorage("wellmusic.player.preciseFLAC") var preciseFLAC: Bool = false

    private init() {
        // 同步 AppState 的 playMode / lyricOffset 等
        // 使用 KVO 或定时同步太复杂，直接在各自属性的 setter 中做

        // 恢复液态玻璃自定义配置
        if let data = defaults.data(forKey: "wellmusic.customLiquidGlassConfig"),
           let config = try? JSONDecoder().decode(WellGlassConfig.self, from: data) {
            customLiquidGlassConfig = config
        } else {
            customLiquidGlassConfig = .default
        }
    }

    // MARK: - 与 AppState 双向同步

    func syncFromAppState() {
        let state = AppState.shared
        if lyricOffset != state.lyricOffset {
            lyricOffset = state.lyricOffset
        }
    }

    func syncLyricOffsetToAppState() {
        AppState.shared.lyricOffset = lyricOffset
    }
}

// MARK: - AccountStore
/// 收藏/账号相关，桥接 AppState.favoriteTracks
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var isLoggedIn: Bool = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 监听 AppState.favoriteTracks 变化来触发 objectWillChange
        // 简化：使用定时器轮询
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }

    func isLiked(track: Track) -> Bool {
        let state = AppState.shared
        return state.favoriteTracks.contains { item in
            Track.from(musicItem: item).id == track.id
        }
    }

    func toggleLike(trackID: Int, track: Track) {
        // 查找对应的 MusicItem
        let state = AppState.shared
        if let existing = state.favoriteTracks.first(where: {
            Track.from(musicItem: $0).id == track.id
        }) {
            state.toggleFavorite(existing)
        } else {
            // 从当前播放队列或基于 track 信息构造 MusicItem
            let core = PlayerCore.shared
            if let queueItem = core.queue.first(where: {
                Track.from(musicItem: $0).id == track.id
            }) {
                state.toggleFavorite(queueItem)
            } else {
                // 构造占位 MusicItem
                let src = MusicSource(rawValue: track.sourcePlatform ?? "netease") ?? .netease
                let item = MusicItem(
                    source: src,
                    title: track.name,
                    artist: track.artistNames,
                    album: track.album.name,
                    albumCoverURL: track.album.picUrl,
                    duration: track.duration,
                    qqSongMid: track.album.albumMid
                )
                state.toggleFavorite(item)
            }
        }
        objectWillChange.send()
    }
}

// MARK: - ToastCenter
/// 简易 Toast 中心（单例，全局 toast 通知）
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var message: String = ""
    @Published var isShowing: Bool = false

    private var hideTimer: Timer?

    func show(_ message: String, duration: TimeInterval = 2.0) {
        self.message = message
        self.isShowing = true
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isShowing = false
            }
        }
    }
}

// MARK: - ScreenAdapter
/// 屏幕尺寸适配器，以 iPhone 14 Pro (393x852) 为基准
enum ScreenAdapter {
    static var designWidth: CGFloat { 393 }
    static var designHeight: CGFloat { 852 }

    static var screenWidth: CGFloat {
        UIScreen.main.bounds.width
    }

    static var screenHeight: CGFloat {
        UIScreen.main.bounds.height
    }

    /// 宽度方向等比缩放
    static func w(_ value: CGFloat) -> CGFloat {
        let scale = screenWidth / designWidth
        let scaled = value * scale
        // clamp 在 0.7x ~ 1.3x
        return min(max(scaled, value * 0.7), value * 1.3)
    }

    /// 高度方向等比缩放
    static func h(_ value: CGFloat) -> CGFloat {
        let scale = screenHeight / designHeight
        let scaled = value * scale
        return min(max(scaled, value * 0.7), value * 1.3)
    }
}

// MARK: - Formatters
enum Formatters {
    /// 格式化时长：秒 -> "mm:ss"
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Platform
enum Platform {
    /// 复制文本到剪贴板
    static func copyToPasteboard(string: String) {
        UIPasteboard.general.string = string
    }

    static var isiOS: Bool { true }
    static var isiPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
}

// MARK: - Theme
enum Theme {
    static var accent: Color { AppTheme.accent }
    static var background: Color { AppTheme.background }
    static var secondaryBackground: Color { AppTheme.secondaryBackground }
}

// MARK: - EmptyStateView
struct EmptyStateView: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
