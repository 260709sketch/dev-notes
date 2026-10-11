import AVFoundation
import Foundation

/// 断开音频输出设备（蓝牙耳机 / 有线耳机拔出）时自动暂停播放。
///
/// 对齐 Kumone `PlayerService` 与 RN v90 的 `BluetoothAutoPause.m`：
/// 监听 `AVAudioSession.routeChangeNotification`，**仅当** reason 为 `.oldDeviceUnavailable`
/// （旧输出设备不可用，即蓝牙断开或耳机拔出）时触发；切换设备（如插入耳机）不触发。
///
/// 与 RN 版的差异：RN 版的开关默认是关闭的，本项目按需求改为**默认开启**，
/// 并保留 `wellmusic.player.bluetoothAutoPause` 开关供用户在设置页关闭。
@MainActor
final class BluetoothAutoPauseManager {
    static let shared = BluetoothAutoPauseManager()

    private var observer: NSObjectProtocol?
    /// 是否已开始监听（避免重复注册）
    private var observing = false

    private init() {}

    /// 开始监听路由变化。幂等，可在 App 启动时安全调用多次。
    func start() {
        guard !observing else { return }
        observing = true
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // 通知可能来自任意线程，统一切回主线程处理
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
            }
        }
    }

    /// 停止监听（一般不需要调用，保留给测试 / 账号切换等场景）
    func stop() {
        guard observing, let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
        observing = false
    }

    // MARK: - 事件处理

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }

        // 仅「旧输出设备不可用」触发：蓝牙断开、拔耳机
        guard reason == .oldDeviceUnavailable else { return }

        // 用户可在设置页关闭（默认开启）
        let enabled = UserDefaults.standard.object(forKey: "wellmusic.player.bluetoothAutoPause") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "wellmusic.player.bluetoothAutoPause")
        guard enabled else { return }

        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let outputName = output?.portName ?? "unknown"
        let portType = output?.portType.rawValue ?? ""

        let core = PlayerCore.shared
        // 仅播放中才需要暂停（对齐 RN handleExternalPause：Playing/Buffering/Loading 才处理）
        guard core.isPlaying || core.isLoading else {
            print("[BluetoothAutoPause] 收到 oldDeviceUnavailable，但当前未在播放，忽略（newOutput=\(outputName) \(portType)）")
            return
        }

        print("[BluetoothAutoPause] oldDeviceUnavailable → 自动暂停（newOutput=\(outputName) \(portType)）")
        core.pause()
    }
}
