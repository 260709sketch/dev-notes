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
