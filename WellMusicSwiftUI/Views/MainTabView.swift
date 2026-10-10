import SwiftUI

/// 主框架：四大 Tab + 屏下 MiniPlayer + 全屏播放页
struct MainTabView: View {
    @EnvironmentObject private var player: PlayerCore
    @State private var showingNowPlaying = false

    var body: some View {
        TabView {
            FavoritesView()
                .tabItem { Label("收藏", systemImage: "heart.fill") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.fill") }
            RadioView()
                .tabItem { Label("电台", systemImage: "dot.radiowaves.left.and.right") }
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
        }
        .safeAreaInset(edge: .bottom) {
            if player.hasActiveTrack {
                MiniPlayerView()
                    .onTapGesture { showingNowPlaying = true }
            }
        }
        .fullScreenCover(isPresented: $showingNowPlaying) {
            NowPlayingView()
        }
    }
}

/// 屏下迷你播放条
struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerCore

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: player.currentItem?.albumCoverURL, size: 42, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentItem?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(player.currentItem?.artist ?? "未知艺术家")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            /// 播放进度细线
            GeometryReader { geo in
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: geo.size.width * min(player.duration > 0 ? player.currentTime / player.duration : 0, 1))
            }
            .frame(height: 2)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// 通用封面图（异步加载 + 占位）
struct ArtworkView: View {
    let url: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholder
            case .empty:
                placeholder
            @unknown default:
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius).fill(AppTheme.secondaryBackground)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    MainTabView()
}