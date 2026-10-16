import SwiftUI
import Combine

/// 原生 Apple Music 歌词宿主（★ 2026-10-16 从 MeloX AppleMusicLyricsView 移植）。
///
/// 数据桥：我们的 `ParsedLyrics`（PlayerService.lyrics）→ MeloX 的 `[WMLyricLine]`
/// （含逐字 syllable：我们的 words: [(text, startMs, endMs)] → LyricSyllable）。
/// 焦点行：听 PlayerCore.currentTime 计算（和旧版歌词页同口径）。
enum WellNativeLyricsAdapter {
    /// ParsedLyrics → WMLyricLine（id 用行序，歌内稳定）
    static func lines(from parsed: ParsedLyrics) -> [WMLyricLine] {
        guard !parsed.isEmpty else { return [] }
        var result: [WMLyricLine] = []
        for (index, line) in parsed.lines.enumerated() {
            let nextTime = parsed.lines[index + 1].time
            let duration = max(nextTime - line.time, 0.5)
            let syllables: [LyricSyllable] = (line.words ?? []).map { word in
                LyricSyllable(text: word.0,
                              startTime: TimeInterval(word.1) / 1000,
                              endTime: TimeInterval(word.2) / 1000)
            }
            result.append(WMLyricLine(
                id: "\(index)",
                time: line.time,
                duration: duration,
                timingKind: syllables.isEmpty ? .lineSynchronized : .precise,
                text: line.text,
                syllables: syllables,
                romanization: line.romaji,
                translation: line.translation
            ))
        }
        return result
    }

    /// 当前播放位置对应的歌词行 id（用于 highlightedLyricID）
    static func highlightedID(in lines: [WMLyricLine], at time: TimeInterval) -> String? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return lines[low].time <= time ? lines[low].id : nil
    }
}

struct WellNativeLyricsHost: View {
    @EnvironmentObject private var player: PlayerService

    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let horizontalPadding: CGFloat

    @State private var lines: [WMLyricLine] = []
    @State private var highlightedID: String?
    @State private var lastLyricsSignature: Int = 0

    var body: some View {
        AppleMusicLyricsView(
            lyrics: lines,
            errorMessage: nil,
            highlightedLyricID: highlightedID
        )
        .environment(PlayerStore.shared)
        .environment(AppSettings.shared)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .padding(.horizontal, horizontalPadding)
        .onReceive(player.$lyrics) { parsed in
            guard let parsed else { return }
            let signature = parsed.lines.count * 1000 + (parsed.lines.first?.time.bitPattern.hashValue ?? 0)
            guard signature != lastLyricsSignature else { return }
            lastLyricsSignature = signature
            lines = WellNativeLyricsAdapter.lines(from: parsed)
        }
        .onReceive(PlayerCore.shared.$currentTime) { time in
            highlightedID = WellNativeLyricsAdapter.highlightedID(in: lines, at: time)
        }
        .onAppear {
            if lines.isEmpty, let parsed = player.lyrics {
                lines = WellNativeLyricsAdapter.lines(from: parsed)
            }
        }
    }
}
