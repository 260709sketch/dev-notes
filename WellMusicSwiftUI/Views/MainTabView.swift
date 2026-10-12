import SwiftUI

/// 主框架：四大 Tab（原生 iOS 26 液态玻璃 / 自定义胶囊栏）+ 屏下 MiniPlayer + 全屏播放页
struct MainTabView: View {
    @EnvironmentObject private var player: PlayerCore
    @EnvironmentObject private var settings: SettingsManager
    @State private var selectedTab: WellTab = .radio
    @State private var showingNowPlaying = false

    /// 四个 Tab 各自的导航路径。
    ///
    /// 每个 tab 一条独立路径，互不干扰：在「发现」里 push 的详情页不会影响
    /// 「音乐库」的导航深度。路径由 `MainTabView` 持有（而不是页面自己），
    /// 这样导航容器可以在 tab 切换时稳定存在 —— 详见 `page(_:_:)` 的说明。
    @State private var radioPath: [Destination] = []
    @State private var favoritesPath: [Destination] = []
    @State private var searchPath: [Destination] = []
    @State private var profilePath: [Destination] = []

    var body: some View {
        tabInterface
            // 根背景：TabView / 全屏 cover 过渡、安全区这些「空隙」都落在这一层。
            // 不显式指定的话会露出系统窗口底色，在切换/滑动时看起来像一块多余的纯色。
            .background(AppTheme.background.ignoresSafeArea())
            .overlay(alignment: .top) { WellToastView() }
            .fullScreenCover(isPresented: $showingNowPlaying) {
                NowPlayingRouterView(onDismiss: { showingNowPlaying = false })
            }
    }

    @ViewBuilder
    private var tabInterface: some View {
        // iOS 26 起一律用系统原生 TabView（系统渲染液态玻璃，性能与观感均为最佳），
        // 不再提供「第三方液态玻璃」选项——自研 shader 效果不如系统原生。
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
            Tab("发现", systemImage: "house.fill", value: WellTab.radio) {
                // 原生 TabView 不提供导航容器，这里同样由我们补上
                // （页面自身已不带 NavigationStack，见 `page(_:_:)`）。
                NavigationStack(path: $radioPath) { DiscoverView() }
            }
            Tab("音乐库", systemImage: "square.grid.2x2.fill", value: WellTab.favorites) {
                NavigationStack(path: $favoritesPath) { FavoritesView() }
            }
            Tab(value: WellTab.search, role: .search) {
                NavigationStack(path: $searchPath) { SearchView() }
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
            Tab("我的", systemImage: "person.crop.circle.fill", value: WellTab.profile) {
                NavigationStack(path: $profilePath) { ProfileView() }
            }
        }
    }

    /// 自定义底部栏：页面 ZStack 切换 + 底部 MiniPlayer + 胶囊栏
    ///
    /// 4 个页面用 ZStack + opacity 常驻（避免切换时销毁重建状态）。
    ///
    /// ⚠️ 导航容器（`NavigationStack`）必须由**这里**统一提供，**不要**写进各个页面内部。
    /// 详见 `page(_:_:)` 的说明。
    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page(.favorites) { FavoritesView() }
                page(.profile) { ProfileView() }
                page(.radio) { DiscoverView() }
                page(.search) { SearchView() }
            }
            // 内层 ZStack 撑满可用空间，把每个页面约束到同一尺寸，
            // 避免切换时因各页内容高度不同而让整棵树上下位移。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // 底栏整体（迷你播放器 + Tab 胶囊）用固定 id，避免随 selectedTab 重建
            VStack(spacing: 8) {
                if player.hasActiveTrack {
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
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: player.hasActiveTrack)
    }

    /// 一个 Tab 的页面：导航容器 + 常驻切换。
    ///
    /// ⚠️ 这里是「切页时大标题与整页跳一下」的修复点。
    ///
    /// 原先的写法是每个页面（`RadioView` / `FavoritesView` / `ProfileView` /
    /// `SearchView`）**各自**在 `body` 里包一个 `NavigationStack` 并设 `navigationTitle`，
    /// 再由 `page()` 用 `opacity` 在 `ZStack` 里切换可见性。问题在于：
    /// 四个 `NavigationStack` 同时存在于视图树中，每个都要独立维护自己的导航栏几何
    /// （大标题的展开/收起、安全区、滚动内容偏移）。切换可见性时，四个导航栏一起
    /// 重新测量，于是标题和整页都会跳一下。
    ///
    /// 正确结构是：**导航容器在切换层之外稳定存在**，页面只作为其内容。
    /// 这样切 tab 只改 `opacity`，完全不触碰导航栏结构。每个 tab 配一条独立的
    /// `NavigationPath`，各自的 push 记录互不干扰。
    @ViewBuilder
    private func page<Content: View>(_ tab: WellTab, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: path(for: tab)) {
            content()
        }
        // ⚠️ 不要加 `.id(tab)` / `.zIndex(...)`：ZStack 里的子视图靠**位置**确定身份，
        // 四个 page 的位置固定不变，加 `zIndex` 反而会在排序变化时触发子树重建。
        .opacity(selectedTab == tab ? 1 : 0)
        .allowsHitTesting(selectedTab == tab)
    }

    /// 每个 Tab 独立的导航路径。
    private func path(for tab: WellTab) -> Binding<[Destination]> {
        switch tab {
        case .radio: return $radioPath
        case .favorites: return $favoritesPath
        case .search: return $searchPath
        case .profile: return $profilePath
        }
    }
}

extension MainTabView {
    static let glassTabItems: [WellTabBar.Item] = [
        .init(tab: .radio, title: "发现", icon: "house"),
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

/// 屏下迷你播放条（对齐 RN/Kumone 浮动胶囊：54pt 高胶囊 + 42pt 封面 + 上一首/播放/下一首）
struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerCore
    @EnvironmentObject private var settings: SettingsManager
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