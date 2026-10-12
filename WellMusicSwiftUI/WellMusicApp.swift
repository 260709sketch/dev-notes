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
                // ★★★ 强制深色模式 —— 跟老版本（1011-0123）一致。
                //
                // 之前误改成 `settingsManager.appTheme.colorScheme`（跟随系统 / 用户设置）：
                // 用户系统是浅色时，nav bar / tab bar / 页面兜底都是 systemBackground 白，
                // 跟 List(.insetGrouped) 的浅灰底色形成断层 → 顶部、底部各冒一条「白条」，
                // 用户已投诉 5 遍。深色模式下 systemBackground 黑、secondarySystemGroupedBackground
                // 黑，nav bar / tab bar / 页面**统一全黑**，没有断层，「白条」从概念上不存在。
                //
                // 历史：22a5dc39 改的设置项保留（深色 / 浅色 / 跟随系统三档仍可切换），
                // 但这里**写死 .dark**，强制整套观感走深色，不让用户在浅色下看到白条。
                .preferredColorScheme(.dark)
                .task {
                    // 恢复已导入的自定义音源并重新激活
                    await WellLXSourceStore.shared.bootstrapIfNeeded()
                }
        }
    }
}