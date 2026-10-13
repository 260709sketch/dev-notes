import Combine
import SwiftUI

/// 主框架（2026-10-13 重写：以用户 10-11 无白边版 `5d7dc59f` 为骨架，功能全套迁入）。
///
/// 骨架要点（与无白边版逐字对齐）：
///   * **每个 Tab 直接挂页面** —— 导航容器（NavigationStack）由各页面自己携带，
///     MainTabView 不做任何包裹（此结构为用户实机验证「无白边」的原始形态）。
///   * `.tabBarMinimizeBehavior(.onScrollDown)` 开启（与无白边版一致）。
///   * 启动动画保留（用户 2026-10-13 指令「这个加上」）；导航栏全透明（用户指令「导航栏保留」）；
///     无任何自加边距。
///   * iOS 16-25 退回自绘毛玻璃胶囊栏 `WellTabBar`（与无白边版一致）。
///
/// 功能注记：页面本体（Discover/Favorites/Search/Profile）、MiniPlayer、
/// 播放页路由等全部为当前最新实现（MPV 内核 / 缩图封面 / 新版迷你条），原样迁入。
///
/// ⚠️ 性能铁律（踩过，整 App 卡死）：
/// **这一层绝不能 `@EnvironmentObject` 整个 `PlayerCore`**（currentTime 每 0.05s 推一次）。
/// 这里只取单例引用（不订阅），用 `onReceive` 只盯 `hasActiveTrack` 这一个粗信号。
struct MainTabView: View {
    @State private var selectedTab: WellTab = .radio
    @State private var showingNowPlaying = false

    private var player: PlayerCore { PlayerCore.shared }
    @State private var hasActiveTrack = false

    /// 启动动画状态（对应 kumone `hasAppeared`）：首帧后从底部上浮 + 淡入
    @State private var hasAppeared = false

    var body: some View {
        tabInterface
            .overlay(alignment: .top) { WellToastView() }
            .fullScreenCover(isPresented: $showingNowPlaying) {
                NowPlayingRouterView(onDismiss: { showingNowPlaying = false })
            }
            // 启动动画：从底部上浮 + 淡入（用户 2026-10-13 指令「这个加上」）
            .offset(y: hasAppeared ? 0 : 24)
            .opacity(hasAppeared ? 1 : 0)
            .onAppear {
                // 延迟 50ms，等视图布局完成后再触发，避免和其他动画冲突
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.45)) {
                        hasAppeared = true
                    }
                }
                hasActiveTrack = player.hasActiveTrack
            }
            .onReceive(player.$hasActiveTrack) { value in
                if hasActiveTrack != value { hasActiveTrack = value }
            }
    }

    @ViewBuilder
    private var tabInterface: some View {
        // iOS 26 起一律用系统原生 TabView（系统渲染液态玻璃，性能与观感均为最佳）。
        // iOS 16-25 无原生液态玻璃，退回自绘毛玻璃胶囊栏 WellTabBar。
        if #available(iOS 26.0, *) {
            iOS26TabInterface
        } else {
            customTabInterface
        }
    }

    /// 原生 iOS 26 TabView：系统渲染液态玻璃，MiniPlayer 挂到 bottom accessory
    @available(iOS 26.0, *)
    private var iOS26TabInterface: some View {
        iOS26TabView
            // 与无白边版一致：开启「滚动 → 底栏最小化」
            .tabBarMinimizeBehavior(.onScrollDown)
            // Apply the accessory through a ViewModifier so the TabView keeps a
            // single identity across the hasActiveTrack toggle.
            .modifier(MiniPlayerAccessoryModifier(
                isActive: hasActiveTrack,
                onOpenNowPlaying: { showingNowPlaying = true }
            ))
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasActiveTrack)
    }

    @available(iOS 26.0, *)
    private var iOS26TabView: some View {
        TabView(selection: $selectedTab) {
            // 与无白边版同构：Tab 直接挂页面（各页面自带 NavigationStack）
            Tab("主页", systemImage: "house.fill", value: WellTab.radio) {
                DiscoverView()
            }
            Tab("音乐库", systemImage: "square.grid.2x2.fill", value: WellTab.favorites) {
                FavoritesView()
            }
            Tab(value: WellTab.search, role: .search) {
                SearchView()
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
            Tab("我的", systemImage: "person.crop.circle.fill", value: WellTab.profile) {
                ProfileView()
            }
        }
    }

    /// 自定义底部栏：页面 ZStack 切换 + 底部 MiniPlayer + 胶囊栏（iOS 16-25）
    ///
    /// 4 个页面用 ZStack + opacity 常驻（避免切换时销毁重建状态），但**必须**给每个
    /// 页面稳定 identity —— 否则切换 tab 时 SwiftUI 会把整个 ZStack 重新求值，底栏的
    /// 液态玻璃层跟着重建，视觉上就是"抖一下"。这里用 `zIndex` + `id` 双固定。
    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page(.favorites) { FavoritesView() }
                page(.profile) { ProfileView() }
                page(.radio) { DiscoverView() }
                page(.search) { SearchView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // 底栏整体（迷你播放器 + Tab 胶囊）用固定 id，避免随 selectedTab 重建
            VStack(spacing: 8) {
                if hasActiveTrack {
                    MiniPlayerView()
                        .onTapGesture { showingNowPlaying = true }
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // iOS 16-25 无系统液态玻璃，统一用自绘毛玻璃胶囊栏
                WellTabBar(items: Self.glassTabItems, selection: $selectedTab) { _ in }
            }
            .padding(.bottom, 6)
            .id("well.bottomDock")
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasActiveTrack)
    }

    /// 页面容器：只做透明度 + 命中测试 + 层级（导航容器由页面自己携带）
    @ViewBuilder
    private func page<Content: View>(_ tab: WellTab, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            // 稳定 identity：切换时只改 opacity / zIndex，不重建视图子树
            .id(tab)
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .zIndex(selectedTab == tab ? 1 : 0)
    }
}

extension MainTabView {
    static let glassTabItems: [WellTabBar.Item] = [
        .init(tab: .radio, title: "主页", icon: "house"),
        .init(tab: .favorites, title: "音乐库", icon: "square.grid.2x2"),
        .init(tab: .search, title: "搜索", icon: "magnifyingglass"),
        .init(tab: .profile, title: "我的", icon: "person.crop.circle"),
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

/// 播放页路由：当前只保留 Apple Music 播放器（其余播放器样式已下线）
struct NowPlayingRouterView: View {
    let onDismiss: () -> Void

    var body: some View {
        AppleMusicPlayerView(
            onOpenDestination: { _ in
                // 目标页（歌手/专辑）在后续迭代接入
            },
            onDismiss: onDismiss
        )
        // 播放页是全屏 cover：出现时放开横屏（触发左右分栏布局），
        // 消失时收回，保证主界面始终竖屏。
        .onAppear { OrientationManager.shared.allowLandscape(true) }
        .onDisappear { OrientationManager.shared.allowLandscape(false) }
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

/// 屏下迷你播放条（对齐 RN/Kumone 浮动胶囊：54pt 高胶囊 + 42pt 封面 + 播放/下一首）
struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerCore
    @Environment(\.colorScheme) private var colorScheme

    private let capsuleHeight: CGFloat = 54

    var body: some View {
        HStack(spacing: 0) {
            // 左：封面 + 歌名/歌手（点击进播放页）
            HStack(spacing: 10) {
                ArtworkView(url: player.currentItem?.albumCoverURL, size: 42, cornerRadius: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.currentItem?.title ?? "未在播放")
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    Text(player.currentItem?.artist ?? "未知艺术家")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .padding(.leading, 7)

            // 右：播放暂停 / 下一首
            //
            // 上一首按钮按设计取消（对齐 RN/Kumone 的迷你条），下一首图标定 18pt。
            HStack(spacing: 6) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
            }
            .padding(.trailing, 15)
            .foregroundStyle(.primary)
        }
        .frame(height: capsuleHeight)
        .background {
            // 与底栏一致：旧版无系统液态玻璃，用毛玻璃胶囊
            Capsule().fill(.regularMaterial)
        }
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0.22), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 12, y: 4)
    }
}

/// 通用封面图（两级缓存 + 防盗链头 + 交叉淡入）
struct ArtworkView: View {
    let url: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    private var resolvedURL: URL? {
        WellArtworkURL.resolved(url, pixelSize: WellArtworkURL.pixelSize(forPoints: size))
    }

    var body: some View {
        WellAsyncImage(url: resolvedURL) {
            placeholder
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
