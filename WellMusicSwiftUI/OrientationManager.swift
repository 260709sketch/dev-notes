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

    /// 切换横屏许可。会立即请求系统重算支持方向。
    func allowLandscape(_ allowed: Bool) {
        guard allowsLandscape != allowed else { return }
        allowsLandscape = allowed
        OrientationSnapshot.mask = allowed
            ? [.portrait, .landscapeLeft, .landscapeRight]
            : .portrait
        requestGeometryUpdate()
    }

    /// 通知系统重新查询支持方向。
    ///
    /// iOS 16 起用 `setNeedsUpdateOfSupportedInterfaceOrientations()`；同时用
    /// `requestGeometryUpdate` 主动催一次，让旋转立刻发生，而不是要等用户
    /// 再转一次手机才生效。
    private func requestGeometryUpdate() {
        guard let scene = Self.activeWindowScene else { return }
        let prefs = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: OrientationSnapshot.mask
        )
        scene.requestGeometryUpdate(prefs)

        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private static var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

/// 仅用于接管方向查询的 AppDelegate。
///
/// 通过 `UIApplicationDelegateAdaptor` 挂到 `WellMusicApp` 上；SwiftUI 不会因此
/// 改变生命周期，只是把方向决策权交给它。
final class WellMusicAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationSnapshot.mask
    }
}
