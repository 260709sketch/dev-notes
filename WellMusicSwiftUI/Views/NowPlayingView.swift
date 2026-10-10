import SwiftUI

/// 全屏播放页：封面 + 播放控制 + 进度 + 歌词
struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerCore
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0
    @State private var showLyrics = true

    var body: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 18) {
                header
                Spacer(minLength: 8)
                coverOrLyrics
                Spacer(minLength: 8)
                titleAndControls
                progressBar
                bottomBar
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .offset(y: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height > 0 { dragOffset = value.translation.height * 0.3 }
                    }
                    .onEnded { value in
                        if value.translation.height > 160 {
                            dismiss()
                        }
                        dragOffset = 0
                    }
            )
        }
        .foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [AppTheme.nowPlayingBackgroundTop, AppTheme.nowPlayingBackgroundBottom],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            Spacer()
            Text("正在播放")
                .font(.subheadline.weight(.medium))
                .opacity(0.8)
            Spacer()
        }
        .overlay(alignment: .leading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
            }
        }
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(uiColor: .systemGray5).opacity(0.25))
                .frame(width: 300, height: 300)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            ArtworkView(url: player.currentItem?.albumCoverURL, size: 300, cornerRadius: 28)
                .rotationEffect(.degrees(player.isPlaying ? 0 : -4))
                .animation(.easeInOut(duration: 0.3), value: player.isPlaying)
        }
        .frame(height: 320)
        .padding(.vertical, 12)
    }

    /// 封面 / 歌词切换区
    private var coverOrLyrics: some View {
        ZStack {
            if showLyrics {
                LyricsView()
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                artwork
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showLyrics.toggle()
                }
            } label: {
                Image(systemName: showLyrics ? "music.note" : "text.quote")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .padding(.trailing, 4)
        }
    }

    private var titleAndControls: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.currentItem?.title ?? "")
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Text(player.currentItem?.artist ?? "未知艺术家")
                        .font(.subheadline)
                        .opacity(0.7)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    if let item = player.currentItem {
                        appState.toggleFavorite(item)
                    }
                } label: {
                    Image(systemName: appState.isFavorite(player.currentItem ?? MusicItem(source: .auto, title: "")) ? "heart.fill" : "heart")
                        .font(.title3)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var progressBar: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.displayTime },
                    set: { player.updateScrubbing(to: $0) }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        player.beginScrubbing(to: player.displayTime)
                    } else {
                        player.endScrubbing(to: player.scrubTime)
                    }
                }
            )
            .tint(.white)
            HStack {
                Text(formatTime(player.displayTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.system(size: 11, design: .monospaced))
            .opacity(0.7)
        }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .frame(width: 64)
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .frame(width: 64)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

#Preview {
    NowPlayingView()
}