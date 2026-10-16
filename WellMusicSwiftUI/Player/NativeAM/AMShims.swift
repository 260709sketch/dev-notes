import SwiftUI
import Combine
import Observation

// MARK: - ★ 2026-10-16 原生 Apple Music 播放器移植：MeloX 侧依赖的最小桥接层
// 把 MeloX 的 PlayerStore / AppSettings 适配到我们的 PlayerCore / 设置存储。
// 注意：effective* / motionProfile / typographyProfile 由
// AppleMusicLyricsResolvedSettings.swift 的 extension AppSettings 提供，本文件不再声明。

@MainActor
@Observable
final class PlayerStore {
    static let shared = PlayerStore()

    struct Song: Identifiable, Equatable {
        let id: Int
    }

    var currentSong: Song?
    var isPlaying: Bool = false
    var isLoading: Bool = false
    var progress: TimeInterval = 0
    var now: TimeInterval = 0
    /// MeloX 侧以 `player.estimatedProgress()` 形式调用（方法，不是属性）
    func estimatedProgress() -> TimeInterval { now }
    var seekRevision: Int = 0

    func seek(to time: TimeInterval) {
        seekRevision &+= 1
        PlayerCore.shared.seek(to: time)
    }

    @ObservationIgnored private var bag: Set<AnyCancellable> = []

    private init() {
        let core = PlayerCore.shared
        core.$isPlaying.receive(on: RunLoop.main)
            .sink { [weak self] v in self?.isPlaying = v }
            .store(in: &bag)
        core.$currentTime.receive(on: RunLoop.main)
            .sink { [weak self] t in
                self?.progress = t
                self?.now = t
            }
            .store(in: &bag)
    }
}

@MainActor
@Observable
final class AppSettings {
    var lyrics = LyricsPrefs()
    var lyricsInterlude = LyricsInterludePreferences()
    var appleMusicLyrics = AppleMusicLyricsPreferences()
    var font = LyricsFontPrefs()

    var appleMusicLyricsScrollHideThreshold: Double = 44
    var wordByWordLyricsAdvanceTime: Double = 0
    var lyricsAdvanceTime: TimeInterval = 0

    func effectiveLyricsAdvanceTime(hasSyllableSyncedLyrics: Bool) -> TimeInterval {
        let usesWordByWord = hasSyllableSyncedLyrics
            ? lyrics.lyricsWordByWord
            : lyrics.lyricsPseudoWordByWord
        return usesWordByWord ? wordByWordLyricsAdvanceTime : lyricsAdvanceTime
    }

    func effectiveLyricsAdvanceTime(for lyrics: [WMLyricLine]) -> TimeInterval {
        effectiveLyricsAdvanceTime(
            hasSyllableSyncedLyrics: lyrics.contains(where: \.isSyllableSynced))
    }

    // MARK: 顶层直读成员（MeloX 的 settings.xxx 直读形态）
    var lyricsAutoFollow: Bool = true
    var lyricsBlurIntensity: Double = 0.55
    var lyricsCurrentLineScale: Double = 1.0
    var lyricsDimAmount: Double = 0.45
    var lyricsDistanceBlurScale: Double = 0.6
    var lyricsDuetLayoutEnabled: Bool = true
    var lyricsFocusCascadeBounce: Bool = true
    var lyricsFocusCascadeBounceEnabled: Bool = true
    var lyricsFocusCascadeBounceGradient: Double = 0.4
    var lyricsFocusPosition: Double = 0.42
    var lyricsFocusPositionRange: ClosedRange<Double> = 0.0...1.0
    var lyricsFocusScaleBounce: Bool = true
    var lyricsFocusScaleBounceDuration: Double = 0.32
    var lyricsFocusScaleBounceEnabled: Bool = true
    var lyricsFollowDelay: Double = 0.0
    var lyricsFontSize: Double = 30
    var lyricsFontWeight: LyricsFontWeight = .semibold
    var lyricsGlowEnabled: Bool = false
    var lyricsGlowIntensity: Double = 0.5
    var lyricsGlowLongSyllablesOnly: Bool = false
    var lyricsHiddenInterfaceBlurScale: Double = 0.5
    var lyricsHighlightGradientReduction: Double = 0.3
    var lyricsHighlightGradientWidth: Double = 0.5
    var lyricsLiftMode: LyricsLiftMode = .word
    var lyricsLongPressToShare: Bool = true
    var lyricsLongSyllableDetectionMode: LyricsLongSyllableDetectionMode = .word
    var lyricsLongSyllableDurationThreshold: Double = 1.0
    var lyricsLongToneExpansionAmount: Double = 0.18
    var lyricsPseudoWordByWord: Bool = true
    var lyricsRomanizationDisplayMode: LyricsTranslationDisplayMode = .focusedLine
    var lyricsRomanizationEnabled: Bool = false
    var lyricsRomanizationFontScale: Double = 0.62
    var lyricsRomanizationOpacity: Double = 0.72
    var lyricsTapToSeek: Bool = true
    var lyricsTranslationDisplayMode: LyricsTranslationDisplayMode = .focusedLine
    var lyricsTranslationEnabled: Bool = true
    var lyricsTranslationFontScale: Double = 0.62
    var lyricsTranslationOpacity: Double = 0.72
    var lyricsWordByWord: Bool = true
}

struct LyricsFontPrefs {
    var name: String = ""
    var weight: Int = 600
}

struct LyricsPrefs {
    var lyricsAutoFollow: Bool = true
    var lyricsBlurIntensity: Double = 0.55
    var lyricsCurrentLineScale: Double = 1.0
    var lyricsDimAmount: Double = 0.45
    var lyricsDistanceBlurScale: Double = 0.6
    var lyricsDuetLayoutEnabled: Bool = true
    var lyricsFocusCascadeBounce: Bool = true
    var lyricsFocusCascadeBounceEnabled: Bool = true
    var lyricsFocusCascadeBounceGradient: Double = 0.4
    var lyricsFocusPosition: Double = 0.42
    var lyricsFocusScaleBounce: Bool = true
    var lyricsFocusScaleBounceDuration: Double = 0.32
    var lyricsFocusScaleBounceEnabled: Bool = true
    var lyricsFollowDelay: Double = 0.0
    var lyricsFontSize: Double = 30
    var lyricsFontWeight: LyricsFontWeight = .semibold
    var lyricsGlowEnabled: Bool = false
    var lyricsGlowIntensity: Double = 0.5
    var lyricsGlowLongSyllablesOnly: Bool = false
    var lyricsHiddenInterfaceBlurScale: Double = 0.5
    var lyricsHighlightGradientReduction: Double = 0.3
    var lyricsHighlightGradientWidth: Double = 0.5
    var lyricsLiftMode: LyricsLiftMode = .word
    var lyricsLongPressToShare: Bool = true
    var lyricsLongSyllableDetectionMode: LyricsLongSyllableDetectionMode = .word
    var lyricsLongSyllableDurationThreshold: Double = 1.0
    var lyricsLongToneExpansionAmount: Double = 0.18
    var lyricsPseudoWordByWord: Bool = true
    var lyricsRomanizationDisplayMode: LyricsTranslationDisplayMode = .focusedLine
    var lyricsRomanizationEnabled: Bool = false
    var lyricsRomanizationFontScale: Double = 0.62
    var lyricsRomanizationOpacity: Double = 0.72
    var lyricsTapToSeek: Bool = true
    var lyricsTranslationDisplayMode: LyricsTranslationDisplayMode = .focusedLine
    var lyricsTranslationEnabled: Bool = true
    var lyricsTranslationFontScale: Double = 0.62
    var lyricsTranslationOpacity: Double = 0.72
    var lyricsWordByWord: Bool = true
}

    // MARK: 静态 Range 成员（MeloX AppSettings static let，原值照抄）
    static let lyricsLiveActivityScrollSpeedRange = 8.0...80.0
    static let lyricsLiveActivityScrollPauseRange = 0.0...3.0
    static let appleMusicLyricsInterfaceAutoHideDelayRange = 3.0...15.0
    static let appleMusicLyricsScrollHideThresholdRange = 40.0...240.0
    static let lyricsFocusPositionRange = 0.05...0.8
    static let lyricsCurrentLineScaleRange = 1.0...1.5
    static let lyricsDistanceBlurScaleRange = 0.0...1.5
    static let lyricsFocusCascadeDelayRange = 0.0...0.1
    static let lyricsFocusCascadeDelayIncreaseRange = 0.0...0.1
    static let lyricsFocusCascadeFollowingDelayRange = 0.0...0.2
    static let lyricsFocusCascadeCatchUpRatioRange = 0.5...1.0
    static let lyricsFocusCascadeChaseSpeedGradientRange = 0.0...1.0
    static let lyricsFocusCascadeDurationRange = 0.2...1.2
    static let lyricsFocusSnapThresholdRange = 0.05...0.5
    static let lyricsFocusCascadeBounceRange = 0.0...0.8
    static let lyricsFocusCascadeBounceGradientRange = 0.0...1.0
    static let lyricsFocusScaleBounceRange = 0.0...0.5
    static let lyricsFocusScaleBounceDurationRange = 0.15...0.8
    static let lyricsFocusColorLeadTimeRange = -0.3...0.3
    static let lyricsLongSyllableDurationThresholdRange = 0.3...1.5
    static let lyricsLongToneExpansionAmountRange = 0.0...0.15
    static let lyricsHighlightGradientWidthRange = 0.4...3.0
    static let lyricsHighlightGradientReductionRange = 0.0...1.0

    // MARK: 分享面板（原版拖 Nuke/选择 store/本地化，按调用面精简）
struct LyricSharePresentation: Identifiable {
    let song: PlayerStore.Song
    let lyrics: [WMLyricLine]
    let initialLyricID: WMLyricLine.ID

    var id: String { "\(song.id) -\(initialLyricID)" }
}

struct LyricSharePayload: Identifiable {
    let id = UUID()
    let song: PlayerStore.Song
    let lyrics: [WMLyricLine]

    var originalLyricsText: String {
        lyrics.map(\.text).joined(separator: "\n")
    }
}

struct LyricsShareExperienceView: View {
    let presentation: LyricSharePresentation

    init(presentation: LyricSharePresentation) {
        self.presentation = presentation
    }

    var body: some View {
        // 一期占位：歌词分享面板（原版依赖 Nuke/选择 store，后续接）
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 28))
            Text("歌词分享")
                .font(.system(size: 14))
        }
        .foregroundStyle(.secondary)
    }
}

/// 歌词分享选择约束（MeloX Sharing 模块精简：只保留被引用到的常量）
enum LyricsSelectionManager {
    static let defaultCharacterLimit = 150
}
