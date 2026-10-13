import SwiftUI

/// 主框架：四大 Tab（原生 iOS 26 液态玻璃 / 自定义胶囊栏）+ 屏下 MiniPlayer + 全屏播放页
///
/// ⚠️ 性能铁律：本视图**绝不订阅 PlayerCore**。
/// PlayerCore.currentTime 由 0.05s tick 驱动（每秒 20 次 @Published 广播），
/// 一旦这里 @EnvironmentObject 订阅它，整棵 TabView（含四个页面容器）会被
/// 每秒拽着重算 20 次——叠加在滚动上就是「每个界面滑动都掉帧」的元凶。
/// 这里只需要 `hasActiveTrack` 一个低频信号（有无播放曲目），用投影 publisher
/// 落到本地 @State 即可。
struct MainTabView: View {
    @State private var selectedTab: WellTab = .radio
    @State private var showingNowPlaying = false

    /// 是否有活跃曲目（决定 MiniPlayer 出现与否）。低频：仅换歌/停止时变化。
    @State private var hasActiveTrack = false

    var body: some View {
        tabInterface
            .overlay(alignment: .top) { WellToastView() }
            .onReceive(PlayerCore.shared.$hasActiveTrack) { hasActiveTrack = $0 }
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
                isActive: hasActiveTrack,
                onOpenNowPlaying: { showingNowPlaying = true }
            ))
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasActiveTrack)
    }

    @available(iOS 26.0, *)
    private var iOS26TabView: some View {
        TabView(selection: $selectedTab) {
            Tab("发现", systemImage: "house.fill", value: WellTab.radio) {
                RadioView()
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

    /// 自定义底部栏：页面 ZStack 切换 + 底部 MiniPlayer + 胶囊栏
    ///
    /// 4 个页面用 ZStack + opacity 常驻（避免切换时销毁重建状态），但**必须**给每个
    /// 页面稳定 identity —— 否则切换 tab 时 SwiftUI 会把整个 ZStack 重新求值，底栏的
    /// 液态玻璃层跟着重建，视觉上就是“抖一下”。这里用 `zIndex` + `id` 双固定。
    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page(.favorites) { FavoritesView() }
                page(.profile) { ProfileView() }
                page(.radio) { RadioView() }
                page(.search) { SearchView() }
            }

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
///
/// ⚠️ 性能约定：本视图**不订阅 PlayerCore**。订阅会让整只胶囊（文字/按钮/阴影）
/// 随 20Hz 的 currentTime 广播每秒重算 20 次——而它挂在 iOS 26 的系统
/// bottom accessory 上，每次重算都可能触发系统 chrome 重新布局，直接拖垮滚动帧率。
///
/// 拆分方案：
/// * 歌名/封面/播放态 —— 低频信号（currentIndex/queue/isPlaying 投影）落 @State；
/// * 2pt 进度细线 —— 拆进 `MiniPlayerProgressLine`，只有那一个小视图高频更新。
struct MiniPlayerView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var track: MusicItem?
    @State private var isPlaying = false

    private let capsuleHeight: CGFloat = 54

    var body: some View {
        HStack(spacing: 0) {
            // 左：封面 + 歌名/歌手（点击进播放页）
            HStack(spacing: 10) {
                ArtworkView(url: track?.albumCoverURL, size: 42, cornerRadius: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track?.title ?? "未在播放")
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    Text(track?.artist ?? "未知艺术家")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .padding(.leading, 7)

            // 右：上一首 / 播放暂停 / 下一首
            HStack(spacing: 12) {
                Button {
                    PlayerCore.shared.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                Button {
                    PlayerCore.shared.togglePlayPause()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                Button {
                    PlayerCore.shared.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20, weight: .semibold))
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
        // 底部进度细线（独立小视图：只有它订阅 20Hz 的播放时间）
        .overlay(alignment: .bottom) { MiniPlayerProgressLine() }
        // 低频信号 → @State（投影 publisher 只在对应属性变化时才发，与 currentTime 无关）
        .onReceive(PlayerCore.shared.$currentIndex) { _ in syncTrack() }
        .onReceive(PlayerCore.shared.$queue) { _ in syncTrack() }
        .onReceive(PlayerCore.shared.$isPlaying) { isPlaying = $0 }
        .onAppear {
            syncTrack()
            isPlaying = PlayerCore.shared.isPlaying
        }
    }

    private func syncTrack() {
        track = PlayerCore.shared.currentItem
    }
}

/// MiniPlayer 底部的 2pt 进度细线。
///
/// 这是整个迷你播放条里**唯一**允许高频订阅播放时间的视图 —— 固定 2pt 高、
/// 宽度随进度变化，重算/重绘面积被压到最小。
private struct MiniPlayerProgressLine: View {
    @ObservedObject private var player = PlayerCore.shared

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(AppTheme.accent)
                .frame(width: geo.size.width * min(player.duration > 0 ? player.currentTime / player.duration : 0, 1), height: 2)
        }
        .frame(height: 2)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 14)
        .padding(.bottom, 3)
        .allowsHitTesting(false)
    }
}

/// 通用封面图（两级缓存 + 防盗链头 + 交叉淡入）
///
/// ⚠️ 必须向图床要**缩图**：原图 1024² 解码后 ≈ 4 MB 位图，列表里铺几十张
/// 就是上百 MB 的解码/内存开销（滚动掉帧的经典来源）。`WellArtworkURL.resolved`
/// 会按显示尺寸换算 pixelSize 档位（含 http→https），图床直接返回小图。
struct ArtworkView: View {
    let url: String?
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    private var resolvedURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        return WellArtworkURL.resolved(url, pixelSize: WellArtworkURL.pixelSize(forPoints: size))
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