import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    /// 底部栏位置微调（设置页「界面 → 底部栏位置」；正 = 更靠下、负 = 更靠上）。
    ///
    /// ⚠️ 应用时是 `42 - value`（不是 `+`）：见 `customTabInterface` 里的符号说明 ——
    /// 贴底容器里底部 padding 越大内容越靠上，所以要「靠下」就得**减** padding。
    @AppStorage("wellmusic.tabbar.bottomOffset") private var tabBarBottomOffset: Double = 0

    /// 是否有活跃曲目（决定 MiniPlayer 出现与否）。低频：仅换歌/停止时变化。
    @State private var hasActiveTrack = false

    /// 手指横向拖动页面产生的位移（松手吸附回 0）。见 `pageSwipeGesture`。
    @State private var pageDragOffset: CGFloat = 0

    /// 键盘遮挡高度（屏幕底 → 键盘上沿）。用于让迷你播放器跟随键盘上移，而 dock 栏不动。
    @State private var keyboardHeight: CGFloat = 0

    /// 各 Tab 独立的导航路径（类型擦除；push 一律用 destination-based NavigationLink）。
    ///
    /// ⚠️ 导航容器（`NavigationStack`）必须由**这里**统一提供，**不要**写进各页面内部：
    /// 四个/五个 `NavigationStack` 同时存在时若由页面自持，切换可见性会让所有导航栏
    /// 一起重新测量，大标题与整页都会跳一下（11:10 版踩过并修复的结构，勿回退）。
    @State private var radioPath = NavigationPath()
    @State private var squarePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var profilePath = NavigationPath()

    var body: some View {
        tabInterface
            .modifier(HiddenChromeBackgroundModifier())
            .overlay(alignment: .top) { WellToastView() }
            .fullScreenCover(isPresented: $showingNowPlaying) {
                NowPlayingRouterView(onDismiss: { showingNowPlaying = false })
            }
            .onReceive(PlayerCore.shared.$hasActiveTrack) { value in
                if hasActiveTrack != value { hasActiveTrack = value }
            }
            .onAppear { hasActiveTrack = PlayerCore.shared.hasActiveTrack }
            // ★ 2026-10-14 用户：点击搜索框时——dock 栏**不上移**（被键盘盖住即可），
            //   只有迷你播放器跟随键盘上移。这里只记录键盘遮挡高度，布局在
            //   `miniPlayerBottomPadding` 里应用。
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                updateKeyboardHeight(from: note)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                if keyboardHeight != 0 { keyboardHeight = 0 }
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
                // 原生 TabView 不提供导航容器，这里由 MainTabView 统一补上
                //（页面自身不带 NavigationStack）。
                NavigationStack(path: $radioPath) { DiscoverView() }
            }
            Tab("精选", systemImage: "sparkles.rectangle.stack.fill", value: WellTab.square) {
                NavigationStack(path: $squarePath) { PlaylistSquareView() }
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

    /// 自定义底部栏：页面**横向分页**（可拖动切页）+ 底部 MiniPlayer + 胶囊栏
    ///
    /// ★ 2026-10-14 用户第三轮两项要求：
    ///   ① 「dock 栏点击切换改成拖动那种，现在的点击切换会界面抖一下」（用户明确
    ///      「这里不是底部栏问题」）—— 原先四个页面用 `opacity` 0/1 切换，新页面从
    ///      全透明变不透明的那一帧，内部 `NavigationStack` 的大标题/滚动位置会重新
    ///      测量，看起来就是抖一下。改成**横向平移**后，四页始终不透明、只做位移，
    ///      抖动自然消失；同时容器整体跟随手指，松手吸附换页。
    ///   ② 四个页面仍**常驻**（横向排布，不销毁重建状态）—— 与原设计保持一致。
    ///
    /// ⚠️ 手势用 `.gesture`（不是 `.highPriorityGesture`/`.simultaneousGesture`）：
    ///   页面内部的横向 ScrollView（发现页/精选页的横滑货架）会优先吃掉自己的拖动，
    ///   两者互不打架；只有在非横滑区域拖动才会走到切页手势。
    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            // ── 页面分页容器 ──
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Self.tabOrder, id: \.self) { tab in
                        NavigationStack(path: path(for: tab)) {
                            pageContent(for: tab)
                        }
                        .frame(width: geo.size.width)
                    }
                }
                .frame(width: geo.size.width * CGFloat(Self.tabOrder.count), alignment: .leading)
                .offset(x: -CGFloat(selectedPageIndex) * geo.size.width + pageDragOffset)
            }
            .clipped()
            .gesture(pageSwipeGesture)

            // ── 迷你播放器：独立一层 ──
            //   ★ 用户要求「dock 栏取消跟随键盘上来、迷你播放器保持跟随，且迷你播放器的
            //     跟随位置改到 dock 栏跟随上来的位置」→ 所以两层解耦：dock 栏位置恒定，
            //     迷你播放器单独吃键盘高度（见 `miniPlayerBottomPadding`）。
            if hasActiveTrack {
                MiniPlayerView()
                    .onTapGesture { showingNowPlaying = true }
                    .padding(.horizontal, 12)
                    .padding(.bottom, miniPlayerBottomPadding)
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // ── dock 栏：位置恒定，不随键盘上移 ──
            // （iOS 16-25 无系统液态玻璃，统一用自绘毛玻璃胶囊栏）
            WellTabBar(items: Self.glassTabItems, selection: $selectedTab) { _ in }
            // 位置（2026-10-14 用户标定）：以**屏幕底**为基准、距底 **42pt**
            //（在 16pt 基础上按用户要求整体**上移 26px**），再叠加设置页
            //「底部栏位置」的微调值。
            //
            // ⚠️★ 2026-10-14 16:50 用户报「靠上和靠下反了」—— 根因是这里的**符号**：
            //   `.padding(.bottom, X)` 在贴底的容器里，X 越大内容越**往上**顶
            //   （当初 16 → 42 就是「上移 26px」，数值变大 = 上移，已是旁证）。
            //   而设置页标签按「正 = 靠下」写，于是滑块方向与文字相反。
            //   修法：减号。正 = 靠下（padding 变小）/ 负 = 靠上（padding 变大），
            //   与 `SettingsManager.tabBarBottomOffset` 的文档语义（正 = 更靠下）对齐。
            //
            // ⚠️ 行程限制：基准本身已距屏幕底 42pt，所以**向下的有效行程只有约 42pt**
            //   （再往下会被屏幕底边裁掉）。向上则不受限（滑杆 -100 时距底 ≈142pt）。
            // （ignoresSafeArea 让基准不再受底部安全区影响；两种语义下都稳定成立。）
            .padding(.bottom, 42 - CGFloat(tabBarBottomOffset))
            .ignoresSafeArea(edges: .bottom)
            .id("well.bottomDock")
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasActiveTrack)
    }

    /// 各 Tab 的页面内容。
    /// 导航容器由 pager 统一提供（见 `customTabInterface`），页面自身不带 NavigationStack。
    @ViewBuilder
    private func pageContent(for tab: WellTab) -> some View {
        switch tab {
        case .radio: DiscoverView()
        case .square: PlaylistSquareView()
        case .search: SearchView()
        case .profile: ProfileView()
        }
    }

    /// 页序（与底部栏 `glassTabItems` 一致）：发现 → 精选 → 搜索 → 我的。
    static let tabOrder: [WellTab] = [.radio, .square, .search, .profile]

    private var selectedPageIndex: Int {
        Self.tabOrder.firstIndex(of: selectedTab) ?? 0
    }

    /// dock 栏距屏幕底的基准距离（再叠加设置页「底部栏位置」微调；正 = 更靠下）。
    private var dockBasePadding: CGFloat { 42 - CGFloat(tabBarBottomOffset) }

    /// 迷你播放器的底部内边距。
    ///
    /// ★ 用户要求：键盘弹出时 dock 栏**不动**，迷你播放器**跟随**，并停在
    ///   「dock 栏若跟随键盘时应在的位置」= 紧贴键盘上沿。
    ///   取两者较大值即可：
    ///   * 键盘收起 → `dockBasePadding + 72`（72 = dock 内容高 64 + 与迷你播放器的 8pt 间距），
    ///     即停在 dock 栏正上方，与改造前的相对位置完全一致；
    ///   * 键盘弹出 → 键盘高度，即贴到键盘上沿。
    private var miniPlayerBottomPadding: CGFloat {
        max(dockBasePadding + 72, keyboardHeight)
    }

    /// 横向拖动切页（为什么用 `.gesture` 而不是 highPriority/simultaneous 见 `customTabInterface`）。
    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // 只认横向意图；竖向留给页面自身的滚动
                guard abs(dx) > abs(dy) * 1.2 else { return }
                let atLeftEnd = selectedPageIndex == 0 && dx > 0
                let atRightEnd = selectedPageIndex == Self.tabOrder.count - 1 && dx < 0
                // 首尾做阻尼，给出「已经到头」的手感
                pageDragOffset = (atLeftEnd || atRightEnd) ? dx * 0.28 : dx
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                var target = selectedPageIndex
                if abs(dx) > abs(dy) * 1.2, abs(dx) > 56 {
                    target = dx < 0
                        ? min(selectedPageIndex + 1, Self.tabOrder.count - 1)
                        : max(selectedPageIndex - 1, 0)
                }
                // 松手吸附：位移与目标页一起动画
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    pageDragOffset = 0
                    if target != selectedPageIndex { selectedTab = Self.tabOrder[target] }
                }
            }
    }

    /// 记录键盘遮挡高度（屏幕底 → 键盘上沿）。
    /// ⚠️ 只在真的变了时才写 `@State`（避免无谓刷新）。
    private func updateKeyboardHeight(from note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let screenHeight = UIScreen.main.bounds.height
        // 键盘完全离屏（隐藏动画过程中）时 minY 已等于屏幕高 → 视为 0
        let overlap = frame.minY >= screenHeight ? 0 : max(0, screenHeight - frame.minY)
        if abs(overlap - keyboardHeight) > 0.5 { keyboardHeight = overlap }
    }

    /// 每个 Tab 独立的导航路径。
    private func path(for tab: WellTab) -> Binding<NavigationPath> {
        switch tab {
        case .radio: return $radioPath
        case .square: return $squarePath
        case .search: return $searchPath
        case .profile: return $profilePath
        }
    }
}

extension MainTabView {
    static let glassTabItems: [WellTabBar.Item] = [
        .init(tab: .radio, title: "发现", icon: "house"),
        .init(tab: .square, title: "精选", icon: "sparkles.rectangle.stack"),
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

/// 屏下迷你播放条（浮动胶囊：52pt 高胶囊 + 32pt 封面 + 上一首/暂停/下一首 三钮等大）
///
/// ⚠️ 性能约定：本视图**不订阅 PlayerCore**。订阅会让整只胶囊（文字/按钮/阴影）
/// 随 20Hz 的 currentTime 广播每秒重算 20 次——而它挂在 iOS 26 的系统
/// bottom accessory 上，每次重算都可能触发系统 chrome 重新布局，直接拖垮滚动帧率。
///
/// 结构（2026-10-14 用户第二轮，按 Apple Music 实机截图 IMG_3964 逐像素标定）：
/// * **不显示播放进度** —— 顶部不再有 2pt 进度细线；
/// * 胶囊高 **52pt**（实机量得 156px @3x）；封面 **32×32**（96px @3x），
///   封面左缘距**胶囊左沿 12pt**（实机量得 72-36=36px @3x）—— 用户要求
///   「封面往右边移动并且改小点」（原 7pt / 42pt）；
/// * 右侧 **上一首 / 播放暂停 / 下一首 三钮等大**：18pt 图标 + 34×34 命中框，
///   钮间距 14pt（钮心间距 48pt，与实机量得的 146px @3x = 48.7pt 一致），
///   末尾距胶囊右沿 10pt（原 15pt，三钮变宽故收窄）。
/// * 歌名/封面/播放态 —— 低频信号（currentIndex/queue/isPlaying/hasActiveTrack 投影）落 @State。
struct MiniPlayerView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var track: MusicItem?
    @State private var isPlaying = false

    private let capsuleHeight: CGFloat = 52
    /// 封面边长（实机量得 96px @3x = 32pt）
    private let artworkSize: CGFloat = 32
    /// 控制图标字号（用户 2026-10-14：三钮统一 17pt）
    private let controlIconSize: CGFloat = 17
    /// 单个控制钮命中框边长（三钮等大）
    private let controlHitSize: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            // 左：封面 + 歌名/歌手（点击进播放页）
            HStack(spacing: 10) {
                ArtworkView(url: track?.albumCoverURL, size: artworkSize, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track?.title ?? "未在播放")
                        .font(.system(size: 14.5, weight: .medium))
                        .lineLimit(1)
                    Text(track?.artist ?? "未知艺术家")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .padding(.leading, 12)

            // 右：上一首 / 播放暂停 / 下一首（三钮等大，Apple Music 同款）
            HStack(spacing: 14) {
                Button {
                    PlayerCore.shared.previous()
                } label: {
                    controlIcon("backward.fill")
                }
                Button {
                    PlayerCore.shared.togglePlayPause()
                } label: {
                    controlIcon(isPlaying ? "pause.fill" : "play.fill")
                }
                Button {
                    PlayerCore.shared.next()
                } label: {
                    controlIcon("forward.fill")
                }
            }
            .padding(.trailing, 10)
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
        // 低频信号 → @State（投影 publisher 只在对应属性变化时才发，与 currentTime 无关）
        //
        // ⚠️ 换歌时必须能刷新：同队列内切 index → 只有 `currentIndex` 变；
        //    换整队列 → `queue` 变；开始/停止播放 → `hasActiveTrack` 变。
        //    三者都监听才能保证「切到下一首后标题立即更新」。
        .onReceive(PlayerCore.shared.$currentIndex) { _ in syncTrack() }
        .onReceive(PlayerCore.shared.$queue) { _ in syncTrack() }
        .onReceive(PlayerCore.shared.$hasActiveTrack) { _ in syncTrack() }
        .onReceive(PlayerCore.shared.$isPlaying) { isPlaying = $0 }
        .onAppear {
            syncTrack()
            isPlaying = PlayerCore.shared.isPlaying
        }
    }

    /// 三个控制钮统一样式（同一字号 + 同一命中框 ⇒ 视觉大小完全一致）。
    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: controlIconSize, weight: .semibold))
            .frame(width: controlHitSize, height: controlHitSize)
            .contentShape(Rectangle())
    }

    private func syncTrack() {
        let next = PlayerCore.shared.currentItem
        if next?.keyOf != track?.keyOf {
            track = next
        }
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