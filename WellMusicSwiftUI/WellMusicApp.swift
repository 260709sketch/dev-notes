import SwiftUI

@main
struct WellMusicApp: App {
    /// 接管屏幕方向：默认竖屏，仅全屏播放页允许横屏。
    @UIApplicationDelegateAdaptor(WellMusicAppDelegate.self) private var appDelegate

    @StateObject private var appState = AppState.shared
    @StateObject private var playerCore = PlayerCore.shared
    @StateObject private var playerService = PlayerService.shared
    @StateObject private var settingsManager = SettingsManager.shared

    init() {
        // 配置音频会话：后台播放 + 耳机/锁屏控制
        AudioSessionManager.configure()
        // 断开蓝牙耳机 / 拔出耳机时自动暂停（默认开启，可在设置页关闭）
        BluetoothAutoPauseManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .environmentObject(playerCore)
                .environmentObject(playerService)
                .environmentObject(settingsManager)
                // 跟随用户主题设置（深/浅/跟随系统，默认跟随系统）—— 与 kumone 完全一致。
                // ★ 白边真正的修法不在「强制某一种颜色」，而在**不要手动铺背景**：
                //   页面全部交给 iOS 系统 Liquid Glass 渲染链自动融合（详见 MainTabView 注释）。
                .preferredColorScheme(settingsManager.appTheme.colorScheme)
                .task {
                    // 恢复已导入的自定义音源并重新激活
                    await WellLXSourceStore.shared.bootstrapIfNeeded()
                }
        }
    }
}