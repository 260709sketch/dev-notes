import SwiftUI
import UIKit

/// 方向快照容器（非隔离）。
///
/// `UIApplicationDelegate` 的方向回调是同步的 Objective-C 方法，处在非 Swift
/// 并发隔离上下文里，无法直接读取 `@MainActor` 类型上的静态属性。这里单独放一个
/// 不带隔离标注的容器，读写都只发生在主线程。
enum OrientationSnapshot {
    /// 当前允许的方向掩码。唯一写入点是 `OrientationManager.allowLandscape`。
    static var mask: UIInterfaceOrientationMask = .portrait
}

/// 全局屏幕方向仲裁。
///
/// 背景：Info.plist 放开了竖屏 + 左右横屏，否则 Apple Music 播放页的横屏
/// 左右分栏布局在真机上永远不会出现。但「放开」是全局的——若不额外限制，
/// 主界面（电台 / 搜索 / 我的）也会跟着旋转，那并不是预期行为。
///
/// 因此这里做一层精确定向：
///   * 默认只允许竖屏；
///   * 仅当**全屏播放页**处于显示状态时，才追加左右横屏。
///
/// 播放页出现 / 消失时调用 `OrientationManager.shared.allowLandscape(_:)`。
@MainActor
final class OrientationManager {
    static let shared = OrientationManager()

    private init() {}

    /// 当前是否允许横屏（仅播放页为 true）。
    private(set) var allowsLandscape = false

    /// 切换横屏许可。
    ///
    /// **只改掩码，不主动催旋转**。原因：`fullScreenCover` 的 `onAppear` 触发时
    /// 演示转场动画还在进行中，此刻调用 `requestGeometryUpdate` /
    /// `setNeedsUpdateOfSupportedInterfaceOrientations` 会让 UIKit 在动画中途
    /// 重算方向并重建层级，实测直接崩溃。
    ///
    /// 交给系统在转场结束后自己查询 `supportedInterfaceOrientationsFor` 即可：
    /// 用户把手机转成横屏时，播放页就会按新掩码进入横屏布局。
    func allowLandscape(_ allowed: Bool) {
        guard allowsLandscape != allowed else { return }
        allowsLandscape = allowed
        OrientationSnapshot.mask = allowed
            ? [.portrait, .landscapeLeft, .landscapeRight]
            : .portrait
    }
}

/// 仅用于接管方向查询的 AppDelegate。
///
/// 通过 `UIApplicationDelegateAdaptor` 挂到 `WellMusicApp` 上；SwiftUI 不会因此
/// 改变生命周期，只是把方向决策权交给它。
final class WellMusicAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.removeChromeBackgrounds()
        return true
    }

    /// ★★★ 移除顶部 / 底部「白色遮挡块」的最终手段（UIKit 层）。
    ///
    /// 现象（用户真机实测）：播放页外的主界面，顶部 nav bar 区域与底部
    /// tab bar 区域各有一块**不透明白色**，把滚动到这些区域的内容硬挡住。
    /// SwiftUI 的 `toolbarBackground(.hidden)` / `toolbarBackgroundVisibility(.hidden)`
    /// 对「系统 TabView + NavigationStack」组合下的 bar 背景无效。
    ///
    /// 这里直接把 `UINavigationBar` / `UITabBar` 的全部 appearance 换成
    /// **完全透明背景**（configureWithTransparentBackground），bar 上的标题与
    /// 图标保持可见，背景层整体移除 —— 内容滚动到状态栏 / Home 指示条区域时
    /// 直接透出，不再被白块遮挡（沉浸式，与 kumone 观感一致）。
    ///
    /// ⚠️ 2026-10-13 修正：顶部导航栏之前「不做处理」导致 iOS 26 大标题模式下
    /// 状态栏下方露出白色矩形。现在统一配置 UINavigationBarAppearance 为默认
    /// 毛玻璃背景，确保导航栏背景延伸到状态栏区域。底部安全区域的白块由
    /// MainTabView.iOS26TabInterface 铺背景色解决（UIKit 层管不到 TabBar 下方）。
    private static func removeChromeBackgrounds() {
        // 导航栏：默认毛玻璃背景，确保延伸到状态栏区域，消除顶部白色矩形
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        let navBar = UINavigationBar.appearance()
        navBar.standardAppearance = nav
        navBar.scrollEdgeAppearance = nav
        navBar.compactAppearance = nav

        // tab bar：全状态（standard / scrollEdge）透明 —— 内容滚动到底部时直接透出
        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundColor = .clear
        tab.backgroundEffect = nil
        tab.shadowColor = .clear
        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = tab
        tabBar.scrollEdgeAppearance = tab
        tabBar.isTranslucent = true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationSnapshot.mask
    }
}
