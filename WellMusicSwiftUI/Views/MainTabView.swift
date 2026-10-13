import Combine
import SwiftUI

/// 主框架：四大 Tab（原生 iOS 26 液态玻璃 / 自定义胶囊栏）+ 屏下 MiniPlayer + 全屏播放页
struct MainTabView: View {
    @EnvironmentObject private var settings: SettingsManager
    @State private var selectedTab: WellTab = .radio
    @State private var showingNowPlaying = false

    /// ⚠️ **这一层绝不能 `@EnvironmentObject` 整个 `PlayerCore`**（踩过，整 App 都卡）。
    ///
    /// `PlayerCore` 每 0.05s 推一次 `currentTime`（逐字歌词需要这个采样率）。
    /// SwiftUI 的 `@EnvironmentObject` 是「任何一个 `@Published` 变了就重算 body」，
    /// 而这里是**所有 tab 页的父视图** —— 一旦订阅，四个 tab 页的 body 会跟着
    /// 每秒重算 20 次，页面里有几十张封面卡时横向滑动直接卡死。
    ///
    /// 这一层真正需要的只是「有没有在播」这个**粗信号**，所以直接取单例引用（不订阅），
    /// 再用 `onReceive` 只盯 `hasActiveTrack` 这一个字段。
    private var player: PlayerCore { PlayerCore.shared }
    @State private var hasActiveTrack = false

    /// 启动动画（对应 kumone `hasAppeared`）：首帧后从底部上浮 + 淡入
    @State private var hasAppeared = false

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
        appContent
            .overlay(alignment: .top) { WellToastView() }
            .fullScreenCover(isPresented: $showingNowPlaying) {
                NowPlayingRouterView(onDismiss: { showingNowPlaying = false })
            }
            // 启动动画：从底部上浮 + 淡入（与 kumone IOSMainWindow.body 同款结构）
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

    /// 主内容（对应 kumone 的 `appContent`）：Tab 界面本体。
    ///
    /// ⚠️ 这里**不要**挂任何 toolbar/chrome 相关的 SwiftUI modifier：
    /// 实测 `toolbarBackgroundVisibility(.hidden, for: .automatic)` 会把导航栏
    /// 样式弄坏（标题漂浮）且修不掉白边（对系统 TabView 的 bar 背景层无效）。
    private var appContent: some View {
        tabInterface
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
            // ★ 稳定身份（用户 2026-10-13 指令：「Dock 切换抖动」修复之一）：
            //   播放状态切换时 MiniPlayerAccessoryModifier 的 if/else 会改 modifier 链，
            //   系统 TabView 若因此被当成新视图重建，底栏会出现白块/抖动。
            //   固定 id 让 TabView 实例身份恒定，modifier 链变化不再触发重建。
            .id("well.iOS26Tab")
            // ⚠️ 刻意**不启用** `.tabBarMinimizeBehavior(.onScrollDown)`：
            //   它是系统路径下唯一的「滚动 → 底栏形态切换」通道 —— 布局重排若被
            //   系统误判为滚动，底栏会在【完整 ↔ 最小化】之间抖动重建，底栏区域
            //   出现白色矩形/闪烁。用户 2026-10-13 指令：所有页面底部白块与
            //   「Dock 切换抖动」有关——最直接的防御就是不让这个联动存在
            //   （底栏保持常驻，代价仅为不随滚动收起）。
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
            // 与 kumone 同构：每个 Tab 内容 = `tabStack(页面)`（NavigationStack 在 tabStack 里）
            Tab("主页", systemImage: "house.fill", value: WellTab.radio) {
                tabStack(.radio) { DiscoverView() }
            }
            Tab("音乐库", systemImage: "square.grid.2x2.fill", value: WellTab.favorites) {
                tabStack(.favorites) { FavoritesView() }
            }
            Tab(value: WellTab.search, role: .search) {
                tabStack(.search) { SearchView() }
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
            Tab("我的", systemImage: "person.crop.circle.fill", value: WellTab.profile) {
                tabStack(.profile) { ProfileView() }
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
                // 与 kumone 同构：page(容器) { tabStack(页面) }，
                // NavigationStack 在 tabStack 里、page 只管透明度与层级。
                page(.favorites) { tabStack(.favorites) { FavoritesView() } }
                page(.profile) { tabStack(.profile) { ProfileView() } }
                page(.radio) { tabStack(.radio) { DiscoverView() } }
                page(.search) { tabStack(.search) { SearchView() } }
            }
            // 内层 ZStack 撑满可用空间，把每个页面约束到同一尺寸，
            // 避免切换时因各页内容高度不同而让整棵树上下位移。
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

    /// 一个 Tab 的导航容器（与 kumone `tabStack` 同构）。
    @ViewBuilder
    private func tabStack<Content: View>(_ tab: WellTab, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: path(for: tab)) {
            content()
        }
    }

    /// 一个 Tab 的页面容器（与 kumone `page` 同构）：
    /// **只做透明度 + 命中测试 + 层级**，导航容器已由 `tabStack` 提供。
    @ViewBuilder
    private func page<Content: View>(_ tab: WellTab, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            // ★ 稳定身份（用户 2026-10-13 指令：「补稳定 .id」）
            .id(tab)
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .zIndex(selectedTab == tab ? 1 : 0)
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