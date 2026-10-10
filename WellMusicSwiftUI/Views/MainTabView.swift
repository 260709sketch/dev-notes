import SwiftUI

/// 主框架：四大 Tab（原生 iOS 26 液态玻璃 / 自定义胶囊栏）+ 屏下 MiniPlayer + 全屏播放页
struct MainTabView: View {
    @EnvironmentObject private var player: PlayerCore
    @EnvironmentObject private var settings: SettingsManager
    @State private var selectedTab: WellTab = .favorites
    @State private var showingNowPlaying = false

    var body: some View {
        tabInterface
            .overlay(alignment: .top) { WellToastView() }
            .fullScreenCover(isPresented: $showingNowPlaying) {
                NowPlayingRouterView(onDismiss: { showingNowPlaying = false })
            }
    }

    @ViewBuilder
    private var tabInterface: some View {
        // iOS 26 + 默认底部栏 = 原生 TabView（系统自动液态玻璃，性能好）
        // iOS 26 + 液态玻璃 = 自定义 WellGlassTabBar
        // iOS 16-25 = 自定义底部栏（WellTabBar 或 WellGlassTabBar）
        if #available(iOS 26.0, *), settings.tabBarStyle == .default {
            iOS26TabInterface
        } else {
            customTabInterface
        }
    }

    /// 原生 iOS 26 TabView：系统渲染液态玻璃，MiniPlayer 挂到 bottom accessory
    @available(iOS 26.0, *)
    private var iOS26TabInterface: some View {
        iOS26TabView
            .tabBarMinimizeBehavior(.onScrollDown)
            // Apply the accessory through a ViewModifier so the TabView keeps a
            // single identity across the hasActiveTrack toggle.
            .modifier(MiniPlayerAccessoryModifier(
                isActive: player.hasActiveTrack,
                onOpenNowPlaying: { showingNowPlaying = true }
            ))
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: player.hasActiveTrack)
    }

    @available(iOS 26.0, *)
    private var iOS26TabView: some View {
        TabView(selection: $selectedTab) {
            Tab("收藏", systemImage: "heart.fill", value: WellTab.favorites) {
                FavoritesView()
            }
            Tab("我的", systemImage: "person.fill", value: WellTab.profile) {
                ProfileView()
            }
            Tab("电台", systemImage: "dot.radiowaves.left.and.right", value: WellTab.radio) {
                RadioView()
            }
            Tab(value: WellTab.search, role: .search) {
                SearchView()
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
        }
    }

    /// 自定义底部栏：页面 ZStack 切换 + 底部 MiniPlayer + 胶囊栏
    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page(.favorites) { FavoritesView() }
                page(.profile) { ProfileView() }
                page(.radio) { RadioView() }
                page(.search) { SearchView() }
            }

            VStack(spacing: 8) {
                if player.hasActiveTrack {
                    MiniPlayerView()
                        .onTapGesture { showingNowPlaying = true }
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if settings.tabBarStyle == .liquidGlass {
                    WellGlassTabBar(items: Self.liquidTabItems, selection: $selectedTab) { _ in }
                } else {
                    WellTabBar(items: Self.glassTabItems, selection: $selectedTab) { _ in }
                }
            }
            .padding(.bottom, 6)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: player.hasActiveTrack)
    }

    @ViewBuilder
    private func page<Content: View>(_ tab: WellTab, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .zIndex(selectedTab == tab ? 1 : 0)
    }
}

extension MainTabView {
    static let glassTabItems: [WellTabBar.Item] = [
        .init(tab: .favorites, title: "收藏", icon: "heart"),
        .init(tab: .profile, title: "我的", icon: "person"),
        .init(tab: .radio, title: "电台", icon: "dot.radiowaves.left.and.right"),
        .init(tab: .search, title: "搜索", icon: "magnifyingglass"),
    ]

    static let liquidTabItems: [WellGlassTabBar.Item] = [
        .init(tab: .favorites, title: "收藏", icon: "heart"),
        .init(tab: .profile, title: "我的", icon: "person"),
        .init(tab: .radio, title: "电台", icon: "dot.radiowaves.left.and.right"),
        .init(tab: .search, title: "搜索", icon: "magnifyingglass"),
    ]
}

/// 全局轻提示（自动换源等）
struct WellToastView: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        Group {
            if center.isShowing {
                Text(center.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.isShowing)
        .allowsHitTesting(false)
    }
}

/// 播放页路由：根据设置中的 nowPlayingMode 选择 Apple Music 播放器或原版播放页
struct NowPlayingRouterView: View {
    @EnvironmentObject private var settings: SettingsManager
    let onDismiss: () -> Void

    var body: some View {
        if settings.nowPlayingMode == .appleMusic {
            AppleMusicPlayerView(
                onOpenDestination: { _ in
                    // 目标页（歌手/专辑）在后续迭代接入
                },
                onDismiss: onDismiss
            )
        } else {
            NowPlayingView()
        }
    }
}

/// iOS 26 原生 TabView 的底部 MiniPlayer accessory
@available(iOS 26.0, *)
private struct MiniPlayerAccessoryModifier: ViewModifier {
    let isActive: Bool
    let onOpenNowPlaying: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.tabViewBottomAccessory {
                MiniPlayerAccessory(onTap: onOpenNowPlaying)
            }
        } else {
            content
        }
    }
}

@available(iOS 26.0, *)
private struct MiniPlayerAccessory: View {
    let onTap: () -> Void

    var body: some View {
        MiniPlayerView()
            .onTapGesture { onTap() }
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