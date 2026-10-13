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
///
/// ⚠️ 不再包含任何 chrome（nav bar / tab bar）干预 —— 曾试过 UIKit appearance
/// 透明化，但 kumone（无白边的参照）**从不对 chrome 做任何设置**。白块的真正
/// 元凶已在页面层解决（150pt 硬编码留白 + UIDesignRequiresCompatibility 移除），
/// 这里恢复为纯方向仲裁，与 kumone 的 AppDelegate 职责一致。
final class WellMusicAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationSnapshot.mask
    }
}
