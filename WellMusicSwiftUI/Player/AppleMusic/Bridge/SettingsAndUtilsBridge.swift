import Foundation
import SwiftUI
import UIKit
import Combine

// MARK: - LyricsAnnotation
enum LyricsAnnotation: String, Codable {
    case off
    case romaji
}

// MARK: - AMLLBackgroundMode
/// AMLL 歌词页的背景渲染方式。
///
/// 流动背景由官方 AMLL 页面里的渲染器（`Fu`）绘制：它从专辑封面取色，
/// 生成持续流动的渐变光斑。这里给用户四档选择，在观感与耗电之间自行取舍。
enum AMLLBackgroundMode: String, Codable, CaseIterable, Identifiable {
    /// 流动背景 + 高斯模糊（推荐）：光斑柔和，GPU 开销可控
    case blurFlow
    /// 流动背景：官方原始观感，光斑清晰锐利
    case flowing
    /// 静态背景：完全不渲染流动层，最省电；只留 SwiftUI 底图
    case still
    /// 不使用 AMLL 背景：完全交给 SwiftUI 的模糊封面
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blurFlow: return "流动背景（模糊）"
        case .flowing: return "流动背景"
        case .still: return "静态背景"
        case .off: return "不使用（跟随播放器）"
        }
    }

    var detail: String {
        switch self {
        case .blurFlow: return "专辑取色流动光斑，叠加高斯模糊，观感柔和、功耗适中"
        case .flowing: return "专辑取色流动光斑，官方原版观感，GPU 占用最高"
        case .still: return "关闭流动渲染，纯底色 + 歌词，最省电"
        case .off: return "背景完全由播放器的模糊封面提供"
        }
    }

    /// 对应的页面端模式名。
    var bridgeValue: String {
        switch self {
        case .blurFlow: return "blurOnly"
        case .flowing: return "flowing"
        case .still: return "still"
        case .off: return "off"
        }
    }

    /// 高斯模糊半径（px）。只有 `blurFlow` 需要。
    var blurRadius: Double {
        switch self {
        case .blurFlow: return 28
        case .flowing, .still, .off: return 0
        }
    }

    /// 背景层不透明度。
    var layerOpacity: Double {
        switch self {
        case .blurFlow: return 0.72
        case .flowing: return 1.0
        case .still, .off: return 0
        }
    }
}

// MARK: - AMLLBackgroundQuality
/// AMLL 流动背景的渲染质量档位。
///
/// 流动背景是 GPU 密集的：它是全屏 GPU 着色器，每帧都要重绘整块背景。
/// 官方默认 `setFPS(40)` + `setRenderScale(0.5)`，本身已经做过一次折中。
/// 这里把它做成用户可调的三档，让低电量 / 老机型可以再降一档。
enum AMLLBackgroundQuality: String, Codable, CaseIterable, Identifiable {
    /// 省电：30 fps + 0.4 倍分辨率
    case power
    /// 均衡：40 fps + 0.5 倍分辨率（官方默认）
    case balanced
    /// 观感优先：60 fps + 0.75 倍分辨率
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .power: return "省电"
        case .balanced: return "均衡"
        case .high: return "高画质"
        }
    }

    var detail: String {
        switch self {
        case .power: return "30 帧 · 0.4x 渲染分辨率，最省电"
        case .balanced: return "40 帧 · 0.5x 渲染分辨率，官方默认"
        case .high: return "60 帧 · 0.75x 渲染分辨率，最流畅但更耗电"
        }
    }

    var fps: Int {
        switch self {
        case .power: return 30
        case .balanced: return 40
        case .high: return 60
        }
    }

    var renderScale: Double {
        switch self {
        case .power: return 0.4
        case .balanced: return 0.5
        case .high: return 0.75
        }
    }
}

// MARK: - AppleMusicBackgroundMode
enum AppleMusicBackgroundMode: String, Codable, CaseIterable {
    case gradient
    case coverBlur
    case dynamicCover
    case dark
}

// MARK: - WellAppTheme
/// 应用外观主题：深色 / 浅色 / 跟随系统
enum WellAppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// 映射到 SwiftUI 的 preferredColorScheme；跟随系统时为 nil
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - NowPlayingMode
/// 「正在播放」页的形态。回迁自 Kumone / wellam 的 NowPlayingMode。
///
/// 说明：`.classic` 已按上游注释停用，`.appleMusic` 即本文件所在的 Apple Music 播放器。
enum NowPlayingMode: String, Codable, CaseIterable, Identifiable {
    case appleMusic
    case immersive
    case immersiveV2
    case vinyl
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .immersive: return "沉浸模式"
        case .immersiveV2: return "沉浸模式 V2"
        case .vinyl: return "唱片模式"
        case .minimal: return "极简模式"
        }
    }

    /// 模式的排版族：compact 类共用紧凑布局。
    var usesCompactLayout: Bool {
        switch self {
        case .appleMusic, .immersiveV2: return true
        case .immersive, .vinyl, .minimal: return false
        }
    }
}

// MARK: - allowsNowPlayingDismiss
/// 控制「正在播放」页是否允许整页下滑关闭。
///
/// 歌词页可见时置 false：避免和歌词滚动 / 拖拽手势互相抢占。
private struct AllowsNowPlayingDismissKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var allowsNowPlayingDismiss: Bool {
        get { self[AllowsNowPlayingDismissKey.self] }
        set { self[AllowsNowPlayingDismissKey.self] = newValue }
    }
}

// MARK: - SettingsManager
/// 桥接 AppState + UserDefaults，满足 AppleMusicPlayerView 对 SettingsManager 的依赖契约。
@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    // MARK: - 外观主题

    /// 应用外观主题（深色 / 浅色 / 跟随系统）
    @AppStorage("wellmusic.appTheme") var appTheme: WellAppTheme = .system

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

    /// 是否使用 AMLL 逐字歌词渲染（Apple Music 播放器）
    @AppStorage("wellmusic.appleMusic.useAMLL") var appleMusicUseAMLL: Bool = true

    /// AMLL 歌词页的背景渲染方式（流动 / 模糊流动 / 静态 / 关闭）
    @AppStorage("wellmusic.amll.backgroundMode") var amllBackgroundMode: AMLLBackgroundMode = .blurFlow

    /// AMLL 流动背景的渲染质量：帧率与分辨率倍率。
    /// 越低越省电；`high` 用于观感优先。
    @AppStorage("wellmusic.amll.backgroundQuality") var amllBackgroundQuality: AMLLBackgroundQuality = .balanced

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

    // MARK: - Apple Music 播放器（回迁自 Kumone / wellam）

    /// 当前「正在播放」页形态
    @AppStorage("wellmusic.player.nowPlayingMode") var nowPlayingMode: NowPlayingMode = .appleMusic

    /// 大封面页是否显示迷你歌词预览（点击可进入歌词页）
    @AppStorage("wellmusic.appleMusic.showLyricPreview") var showLyricPreview: Bool = false

    /// 是否常驻显示音量条（false 时走音量按钮 + 浮层）
    @AppStorage("wellmusic.appleMusic.showVolume") var showVolumeControl: Bool = false

    /// 自定义配色（十六进制，空串表示用默认色）
    @AppStorage("wellmusic.appleMusic.primaryHex") var appleMusicPrimaryHex: String = ""
    @AppStorage("wellmusic.appleMusic.secondaryHex") var appleMusicSecondaryHex: String = ""
    @AppStorage("wellmusic.appleMusic.accentHex") var appleMusicAccentHex: String = ""
    @AppStorage("wellmusic.appleMusic.volumeHex") var appleMusicVolumeHex: String = ""

    /// 呼吸/律动强度（0...1）
    @AppStorage("wellmusic.player.breath") var breath: Double = 0.6

    /// 进度条样式（0 为默认）
    @AppStorage("wellmusic.player.progressBarStyle") var progressBarStyle: Int = 0

    /// 背景模式
    @AppStorage("wellmusic.appleMusic.backgroundMode") var appleMusicBackgroundMode: AppleMusicBackgroundMode = .gradient

    /// 是否启用动态封面
    @AppStorage("wellmusic.appleMusic.dynamicCoverEnabled") var dynamicCoverEnabled: Bool = true

    /// 控件是否使用封面颜色
    @AppStorage("wellmusic.player.controlsUseCoverColor") var controlsUseCoverColor: Bool = true

    // MARK: - Player

    @AppStorage("wellmusic.showSongVIPBadge") var showSongVIPBadge: Bool = false

    @AppStorage("wellmusic.player.autoSkipOnFailure") var autoSkipOnFailure: Bool = true

    /// 断开蓝牙耳机 / 拔出耳机时自动暂停播放（默认开启）
    @AppStorage("wellmusic.player.bluetoothAutoPause") var bluetoothAutoPause: Bool = true

    @AppStorage("wellmusic.player.swipeSwitchSong") var swipeSwitchSong: Bool = true

    /// 无损/高音质
    @AppStorage("wellmusic.player.preciseFLAC") var preciseFLAC: Bool = false

    private init() {
        // 同步 AppState 的 playMode / lyricOffset 等
        // 使用 KVO 或定时同步太复杂，直接在各自属性的 setter 中做
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
        // ⚠️ 这里**不能**用定时器轮询 `objectWillChange.send()`。
        //
        // 曾经写成 0.5s 一次的 `Timer { objectWillChange.send() }`，而
        // `AppleMusicPlayerView` 顶层就 `@ObservedObject account`。结果是
        // **整个播放页每 0.5 秒无条件全量重算一次** —— 包括 `UIScreen.main.bounds`、
        // 安全区遍历、preference/anchor 层，以及最贵的
        // `AMLLWebRepresentable.updateUIView` → 往 474KB 的 WebGL 歌词页
        // 下发 `evaluateJavaScript`。2Hz 的整页重算足以让主线程饱和，
        // 表现为「打开播放器就卡死」。
        //
        // 正确做法：只在收藏集合**真的变化**时通知。
        // 收藏的写入点统一在 `AppState.favoriteTracks`（`@Published`），
        // 直接订阅它即可，天然去重、零轮询。
        AppState.shared.$favoriteTracks
            .dropFirst()                       // 初值不需要通知（视图初始化时会自己读）
            .removeDuplicates { lhs, rhs in
                // 只比 id 列表，避免 `MusicItem` 整体相等性比较的开销与误判。
                lhs.map(\.id) == rhs.map(\.id)
            }
            .sink { [weak self] _ in
                // 转发成自身的变更信号，让观察 `AccountStore` 的视图重算。
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
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
