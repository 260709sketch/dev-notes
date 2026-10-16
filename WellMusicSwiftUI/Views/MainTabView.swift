import SwiftUI
import UIKit

/// 主框架：四大 Tab（原生 iOS 26 液态玻璃 / 自定义胶囊栏）+ 屏下 MiniPlayer + 全屏播放页
///
/// ⚠️ 性能铁律：本视图**绝不订阅 PlayerCore**。
/// PlayerCore.currentTime 由 0.05s tick 驱动（每秒 20 次 @Published 广播），
/// 一旦这里 @EnvironmentObject 订阅它，整棵 TabView（含四个页面容器）会被
/// 每秒拽着重算 20 次——叠加在滚动上就是「每个界面滑动都掉帧」的元凶。
/// 这里只需要 `hasActiveTrack` 一个低频信号（有无播放曲目），用投影 publisher
/// 落到本地 @State 即可。
struct MainTabView: View {
    @EnvironmentObject private var settings: SettingsManager
    @State private var selectedTab: WellTab = .radio
    @State private var showingNowPlaying = false

    /// 底部栏位置微调（设置页「界面 → 底部栏位置」；正 = 更靠下、负 = 更靠上）。
    ///
    /// ⚠️ 应用时是 `42 - value`（不是 `+`）：见 `customTabInterface` 里的符号说明 ——
    /// 贴底容器里底部 padding 越大内容越靠上，所以要「靠下」就得**减** padding。
    @AppStorage("wellmusic.tabbar.bottomOffset") private var tabBarBottomOffset: Double = 50

    /// 是否有活跃曲目（决定 MiniPlayer 出现与否）。低频：仅换歌/停止时变化。
    @State private var hasActiveTrack = false

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
            // 自定义音源脚本上报更新 → 弹窗询问是否去更新。
            // ⚠️ 交给独立叶视图渲染，**不要**在这里 @ObservedObject 订阅音源仓库：
            //    该仓库每次成功取链都会 appendLog（requestLogs 是 @Published），
            //    在根部订阅就等于「每解析一首歌就重算整棵 Tab 树」。
            .overlay { WellLXUpdateAlertPresenter() }
            .fullScreenCover(isPresented: $showingNowPlaying) {
                NowPlayingRouterView(onDismiss: { showingNowPlaying = false })
            }
            .onReceive(PlayerCore.shared.$hasActiveTrack) { value in
                if hasActiveTrack != value { hasActiveTrack = value }
            }
            .onAppear { hasActiveTrack = PlayerCore.shared.hasActiveTrack }
            // 播放页发出的「跳歌手 / 跳专辑」请求。
            //
            // ★ 2026-10-14 起播放器有了**自己的内部导航栈**（见 `NowPlayingRouterView`），
            //   点歌手/专辑不再走这条通道 —— 这条保留为「跳出播放器、push 进当前 Tab」
            //   的备用入口，`NowPlayingNavigator` 仍在，未被调用时不产生任何开销。
            .onReceive(NowPlayingNavigator.shared.$pending) { destination in
                guard let destination else { return }
                pushNowPlayingDestination(destination)
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
            // ⚠️ `Tab` 的结构（是否 search 角色）随设置变化，切换时必须让
            //   TabView 重建一次，否则系统可能沿用旧结构（表现为「切了没反应」）。
            //   `.id` 绑到开关上，切换即重建。
            Tab("发现", systemImage: "house.fill", value: WellTab.radio) {
                // 原生 TabView 不提供导航容器，这里由 MainTabView 统一补上
                //（页面自身不带 NavigationStack）。
                // 页面内容统一走 `pageContent`，这样「播放页跳歌手/专辑」的
                // navigationDestination 两个分支共用同一份实现。
                NavigationStack(path: $radioPath) { pageContent(for: .radio) }
            }
            Tab("精选", systemImage: MainTabView.squareTabSymbol, value: WellTab.square) {
                NavigationStack(path: $squarePath) { pageContent(for: .square) }
            }
            // ★ 2026-10-15 用户：搜索界面新旧可切换（设置 → 界面「旧版搜索界面」）。
            //   新版 = 普通 tab + 页面自绘常驻搜索框；旧版 = 系统 search 角色
            //   （进页折叠的系统搜索栏）。
            if settings.searchLegacyUI {
                Tab(value: WellTab.search, role: .search) {
                    NavigationStack(path: $searchPath) { pageContent(for: .search) }
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
            } else {
                Tab("搜索", systemImage: "magnifyingglass", value: WellTab.search) {
                    NavigationStack(path: $searchPath) { pageContent(for: .search) }
                }
            }
            Tab("我的", systemImage: "person.crop.circle.fill", value: WellTab.profile) {
                NavigationStack(path: $profilePath) { pageContent(for: .profile) }
            }
        }
        // ⚠️ `Tab` 的结构（是否 search 角色）随设置变化：`.id` 绑到开关上，
        //   切换时强制 TabView 重建一次（否则系统可能沿用旧结构，表现为「切了没反应」）。
        .id(settings.searchLegacyUI)
    }

    /// 自定义底部栏：页面 ZStack 切换 + 底部 MiniPlayer + 胶囊栏
    ///
    /// 4 个页面用 ZStack + opacity 常驻（避免切换时销毁重建状态），但**必须**给每个
    /// 页面稳定 identity —— 否则切换 tab 时 SwiftUI 会把整个 ZStack 重新求值，底栏的
    /// 液态玻璃层跟着重建，视觉上就是“抖一下”。这里用 `zIndex` + `id` 双固定。
    ///
    /// ⚠️★ 2026-10-14 用户第三轮末：⑥「dock 栏点击切换改成拖动那种」**已按用户要求回退**
    ///   （用户原话「算了你把dock栏切换改回去」）。中间曾实现「横向分页 + 拖动切页」
    ///   （HStack 排布 + `.offset` + 手势），现恢复为**点击切换 + opacity**，与回退前
    ///   的实现完全一致；同轮的「播放页跳转」保留。
    ///
    /// ⚠️★ 2026-10-14 用户第四轮：「键盘跟随这个回退」—— 原需求 ⑭b 整条回退。
    ///   中间曾把 dock 栏与迷你播放器拆成两层（dock 恒定 + 迷你播放器单独吃键盘高度），
    ///   现恢复为**单层 `VStack(spacing: 8)` 整体随键盘上移**，与改造前完全一致；
    ///   `keyboardHeight` / `miniPlayerBottomPadding` / `dockBasePadding` 与两个键盘
    ///   通知监听一并删除。
    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            // ── 页面层：ZStack + opacity 常驻切换 ──
            ZStack {
                page(.profile) { pageContent(for: .profile) }
                page(.radio) { pageContent(for: .radio) }
                page(.square) { pageContent(for: .square) }
                page(.search) { pageContent(for: .search) }
            }

            // 底栏整体（迷你播放器 + Tab 胶囊）用固定 id，避免随 selectedTab 重建
            //
            // ★★ 2026-10-14 用户第四轮：「键盘跟随这个回退」—— 需求 ⑭b 整条回退。
            //   中间曾把 dock 栏与迷你播放器**拆成两层**（dock 恒定不动、迷你播放器单独
            //   吃键盘高度 `miniPlayerBottomPadding`）；现恢复为**单层 VStack(spacing: 8)**
            //   —— 迷你播放器与 dock 栏作为整体一起被键盘顶上去，与改造前完全一致。
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

    /// 单个 Tab 的页面容器：稳定的 `NavigationStack` + 按选中态切换 opacity。
    ///
    /// 导航容器在切换层之外稳定存在，页面只作为其内容；切 tab 只改 opacity，
    /// 不触碰导航栏结构（大标题不跳）。
    @ViewBuilder
    private func page<Content: View>(_ tab: WellTab, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: path(for: tab)) {
            content()
        }
        .opacity(selectedTab == tab ? 1 : 0)
        .allowsHitTesting(selectedTab == tab)
    }

    /// 各 Tab 的页面内容。
    /// 导航容器由 `page(_:)` 统一提供，页面自身不带 NavigationStack。
    ///
    /// ★ 2026-10-14：挂上播放页的跳转目标（歌手主页 / 专辑详情）。
    ///   播放页是 fullScreenCover，自己不在导航栈里，只能把目标 push 到这里。
    @ViewBuilder
    private func pageContent(for tab: WellTab) -> some View {
        Group {
            switch tab {
            case .radio: DiscoverView()
            case .square: PlaylistSquareView()
            case .search: SearchView()
            case .profile: ProfileView()
            }
        }
        .navigationDestination(for: NowPlayingDestination.self) { destination in
            nowPlayingDestinationView(destination)
        }
    }

    /// 播放页跳转目标 → 真实页面。
    @ViewBuilder
    private func nowPlayingDestinationView(_ destination: NowPlayingDestination) -> some View {
        NowPlayingDestinationView(destination: destination)
    }

    /// 把播放页请求的跳转 push 进**当前 Tab** 的导航栈，然后清掉请求。
    private func pushNowPlayingDestination(_ destination: NowPlayingDestination) {
        showingNowPlaying = false
        switch selectedTab {
        case .radio: radioPath.append(destination)
        case .square: squarePath.append(destination)
        case .search: searchPath.append(destination)
        case .profile: profilePath.append(destination)
        }
        NowPlayingNavigator.shared.consume()
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
    /// 精选 Tab 图标：优先「方框内音符」（Apple Music 资料库样式），
    /// 逐个运行时探测符号名，取第一个当前系统存在的；全不存在退化为 music.note。
    static let squareTabSymbol: String = {
        for name in ["music.note.square.stack.fill", "music.note.square.stack", "music.note.list", "music.note"] {
            if UIImage(systemName: name) != nil { return name }
        }
        return "music.note"
    }()

    static let glassTabItems: [WellTabBar.Item] = [
        .init(tab: .radio, title: "发现", icon: "house"),
        .init(tab: .square, title: "精选", icon: squareTabSymbol),
        .init(tab: .search, title: "搜索", icon: "magnifyingglass"),
        .init(tab: .profile, title: "我的", icon: "person.crop.circle"),
    ]
}

/// 音源更新提示的挂载点（问题11）。
///
/// ⚠️ 单独做成一个**叶视图**，不要在 `MainTabView` 里直接 `@ObservedObject` 订阅
/// `WellLXSourceStore` —— 该仓库每次成功取链都会 `appendLog`（`requestLogs` 是 @Published），
/// 在根部订阅就等于「每解析一首歌就把整棵 Tab 树重算一遍」，
/// 正是本项目反复踩过的「高频 publisher 别在根部订阅」。
/// 放在这里，重算范围只有这个空视图本身。
struct WellLXUpdateAlertPresenter: View {
    @ObservedObject private var store = WellLXSourceStore.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            // ★ 2026-10-16 用户问题16：更新提示改为**底部弹出**（原来是中央 alert）
            .sheet(isPresented: Binding(
                get: { store.pendingUpdateAlert != nil },
                set: { newValue in if !newValue { store.dismissUpdateAlert() } }
            )) {
                if let notice = store.pendingUpdateAlert {
                    WellLXUpdateBottomCard(notice: notice)
                        .presentationDetents([.medium])
                }
            }
    }
}

/// 音源更新提示（底部卡片）：音源名 + 说明 + 操作按钮。
private struct WellLXUpdateBottomCard: View {
    let notice: WellLXUpdateNotice
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WellLXSourceStore.shared

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("\(notice.sourceName) 有更新")
                    .font(.headline)
                if !notice.log.isEmpty {
                    Text(notice.log)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(6)
                }
            }
            .padding(.top, 20)

            // 应用侧检查到的新版本：可直接一键覆盖本地脚本
            if let script = notice.inAppUpdateScript, let id = notice.sourceID {
                Button {
                    Task {
                        if let target = store.sources.first(where: { $0.id == id }) {
                            try? await store.applyUpdate(script, to: target)
                        }
                        store.dismissUpdateAlert()
                    }
                } label: {
                    Text("立即更新")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            if notice.hasLink, let url = URL(string: notice.updateUrl) {
                Button {
                    UIApplication.shared.open(url)
                    store.dismissUpdateAlert()
                } label: {
                    Text("打开更新地址")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            Button {
                store.dismissUpdateAlert()
            } label: {
                Text("关闭")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 20)
    }
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
///
/// ★★ 2026-10-14 用户：「播放器界面打开歌手主页怎么自动退出播放器？」
///
/// 原先点歌手名 / 专辑名走的是 `NowPlayingNavigator.request(...)` + `onDismiss()`，
/// 也就是**先把播放页关掉**、再把目标 push 进当前 Tab 的导航栈 —— 用户体验上就是
/// 「点一下歌手名，播放器没了」。
///
/// 现在改为：播放器**自带一个内部 `NavigationStack`**，点歌手 / 专辑直接在
/// 播放器里 push，播放器不退出；播放器关闭时清空这条内部路径。
struct NowPlayingRouterView: View {
    let onDismiss: () -> Void
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            AppleMusicPlayerView(
                onOpenDestination: { destination in
                    // ★ 在播放器**内部** push —— 不退出播放器。
                    path.append(destination)
                },
                onDismiss: onDismiss
            )
            .navigationDestination(for: NowPlayingDestination.self) { destination in
                NowPlayingDestinationView(destination: destination)
            }
        }
        // 播放器关闭时清空内部导航路径，下次打开回到播放器本体
        .onDisappear { path = NavigationPath() }
    }
}

/// 播放页跳转目标 → 真实页面。
///
/// 播放器内部导航栈与各 Tab 的导航栈**共用**这一份实现，避免两处漂移。
struct NowPlayingDestinationView: View {
    let destination: NowPlayingDestination

    var body: some View {
        switch destination.kind {
        case .artist:
            // ★ 2026-10-14：**必须**把平台传下去。歌手主页原先只查网易云，
            //   QQ / 酷狗 的歌从播放页点歌手名跳进来会是一张全空的页面。
            WellArtistHomeView(artistId: destination.platformId,
                               artistName: destination.name,
                               coverURL: destination.coverURL,
                               platform: destination.platform)
        case .album:
            WellPlaylistDetailView(
                source: .album(id: destination.platformId,
                               platform: destination.platform,
                               name: destination.name,
                               artist: destination.artistName,
                               mid: destination.platformId),
                coverURL: destination.coverURL,
                creatorName: destination.artistName)
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
                    controlIcon("backward.fill", size: 15)
                }
                Button {
                    PlayerCore.shared.togglePlayPause()
                } label: {
                    controlIcon(isPlaying ? "pause.fill" : "play.fill")
                }
                Button {
                    PlayerCore.shared.next()
                } label: {
                    controlIcon("forward.fill", size: 15)
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

    /// 三个控制钮统一样式（同一命中框；图标字号分档 ——
    /// backward/forward 的填充色块视觉重量远大于 pause 两竖条，同字号会显大，故降一档）。
    private func controlIcon(_ name: String, size: CGFloat = 17) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
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
        // ★ 2026-10-16 性能（照 kumone 实测）：行内小图关闭交叉淡入 ——
        //   滚动回收行重新显示时省一次 opacity 动画合成
        WellAsyncImage(url: resolvedURL, animated: false) {
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