import SwiftUI
import Combine
import Observation

// MARK: - ★ 2026-10-16 原生 Apple Music 播放器移植：MeloX 侧依赖的最小桥接层
// 把 MeloX 的 PlayerStore / AppSettings 适配到我们的 PlayerCore / 设置存储。

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
    var estimatedProgress: TimeInterval = 0
    var seekRevision: Int = 0

    func seek(to time: TimeInterval) {
        seekRevision &+= 1
        PlayerCore.shared.seek(to: time)
    }

    @ObservationIgnored private var bag: Set<AnyCancellable> = []
    @ObservationIgnored private var ticker: Timer?

    private init() {
        let core = PlayerCore.shared
        core.$isPlaying.receive(on: RunLoop.main)
            .sink { [weak self] v in self?.isPlaying = v }
            .store(in: &bag)
        core.$currentTime.receive(on: RunLoop.main)
            .sink { [weak self] t in
                self?.progress = t
                self?.now = t
                self?.estimatedProgress = t
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
    var appleMusicLyricsMotionProfile = AppleMusicLyricsMotionProfile.iOS26_6
    var appleMusicLyricsTypographyProfile = AppleMusicLyricsTypographyProfile.iOS26_6

    // effective*（默认值取 Apple Music 观感；后续可按设置联动）
    var effectiveAppleMusicLyricsCascadeDelay: Double { 0.10 }
    var effectiveAppleMusicLyricsCascadeDelayIncrease: Double { 0.02 }
    var effectiveAppleMusicLyricsCascadeDuration: Double { 0.55 }
    var effectiveAppleMusicLyricsCatchUpRatio: Double { 0.55 }
    var effectiveAppleMusicLyricsChaseSpeedGradient: Double { 0.65 }
    var effectiveAppleMusicLyricsCurrentLineScale: Double { lyrics.lyricsCurrentLineScale }
    var effectiveAppleMusicLyricsFocusColorLeadTime: Double { 0.18 }
    var effectiveAppleMusicLyricsFollowingDelay: Double { lyrics.lyricsFollowDelay }
    var effectiveAppleMusicLyricsLineSpacing: Double { 14 }
    var effectiveAppleMusicLyricsPrimaryFontSize: Double { lyrics.lyricsFontSize }
    var effectiveAppleMusicLyricsSnapThreshold: Double { 0.32 }
    var effectiveLyricsAdvanceTime: Double { 0.0 }
    var wordByWordLyricsAdvanceTime: Double { 0.0 }
    var lyricsPseudoWordByWord: Bool = true
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
