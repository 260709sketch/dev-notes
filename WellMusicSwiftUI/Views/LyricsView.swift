import SwiftUI

/// 歌词视图：优先逐字（卡拉OK 高亮），无逐字时逐行 LRC（含翻译）
struct LyricsView: View {
    @EnvironmentObject private var player: PlayerCore
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let wordLyric = currentWordLyric, !wordLyric.isEmpty {
                WordLyricsView(lines: wordLyric, currentTime: displayTime)
            } else if !appState.currentLrc.isEmpty {
                LineLyricsView(lines: appState.currentLrc, currentTime: displayTime)
            } else {
                emptyState
            }
        }
    }

    /// 拖动进度条时跟随预览时间，保证歌词实时预览不落后。
    /// 叠加用户配置的歌词同步偏移（正值=高亮提前，校准输出延迟）
    private var displayTime: TimeInterval {
        player.displayTime + appState.lyricOffset
    }

    private var currentWordLyric: [WordLyricLine] { appState.currentWordLyric }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 30))
                .opacity(0.3)
            Text("暂无歌词")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("可在设置中选择歌词来源")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 逐字（卡拉OK）歌词

private struct WordLyricsView: View {
    let lines: [WordLyricLine]
    let currentTime: TimeInterval

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let active = line.start <= currentTime && currentTime <= line.end
                        KaraokeLineView(line: line, currentTime: currentTime, active: active)
                            .id("w\(index)")
                            .opacity(active ? 1 : 0.35)
                        if active, let trans = translationForLine(start: line.start) {
                            Text(trans)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .padding(.vertical, 60)
            }
            .onChange(of: currentTime) { newTime in
                if let idx = activeIndex(at: newTime) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("w\(idx)", anchor: .center)
                    }
                }
            }
            .onAppear {
                if let idx = activeIndex(at: currentTime) {
                    proxy.scrollTo("w\(idx)", anchor: .center)
                }
            }
        }
    }

    private func activeIndex(at time: TimeInterval) -> Int? {
        for (i, line) in lines.enumerated() where line.start <= time && time < line.end {
            return i
        }
        // 未知区间时定位到最接近的行
        if let last = lines.last(where: { $0.start <= time }) {
            return lines.firstIndex(where: { $0.id == last.id })
        }
        return nil
    }

    /// 从逐行歌词中按时间找翻译（若平台同时返回）
    private func translationForLine(start: TimeInterval) -> String? {
        appStateCurrentLrc.first { abs($0.time - start) < 0.05 }?.translated
    }

    @EnvironmentObject private var appState: AppState
    private var appStateCurrentLrc: [LrcLine] { appState.currentLrc }
}

/// 单行逐字：按 time 进度把已唱字染成主题色
private struct KaraokeLineView: View {
    let line: WordLyricLine
    let currentTime: TimeInterval
    let active: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
                let played = currentTime >= word.start
                Text(word.char)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(played ? AppTheme.accent : Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 1)
            }
        }
        .scaleEffect(active ? 1.06 : 1)
        .animation(.easeInOut(duration: 0.2), value: active)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
    }
}

// MARK: - 逐行 LRC 歌词

private struct LineLyricsView: View {
    let lines: [LrcLine]
    let currentTime: TimeInterval

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let active = isActive(line, index: index)
                        VStack(spacing: 3) {
                            Text(line.text)
                                .font(active ? .title3.weight(.semibold) : .body)
                                .foregroundStyle(active ? .white : Color.white.opacity(0.4))
                                .multilineTextAlignment(.center)
                            if active, let trans = line.translated, !trans.isEmpty {
                                Text(trans)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.65))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .id("l\(index)")
                        .scaleEffect(active ? 1.05 : 1)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 60)
            }
            .onChange(of: currentTime) { newTime in
                if let idx = activeIndex(at: newTime) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("l\(idx)", anchor: .center)
                    }
                }
            }
            .onAppear {
                if let idx = activeIndex(at: currentTime) {
                    proxy.scrollTo("l\(idx)", anchor: .center)
                }
            }
        }
    }

    private func isActive(_ line: LrcLine, index: Int) -> Bool {
        if currentTime >= line.time, index + 1 >= lines.count { return true }
        if let next = lines[safe: index + 1] {
            return line.time <= currentTime && currentTime < next.time
        }
        return false
    }

    private func activeIndex(at time: TimeInterval) -> Int? {
        for (i, line) in lines.enumerated() where isActive(line, index: i) { return i }
        if let last = lines.last(where: { $0.time <= time }) {
            return lines.firstIndex { $0.id == last.id }
        }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}