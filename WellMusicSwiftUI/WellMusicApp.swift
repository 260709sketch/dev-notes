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
        // 全局 nav bar 背景色 = systemGroupedBackground（与 AppTheme.background 同色）。
        // 不设的话 nav bar 默认是 systemBackground 白，跟下方 List(.insetGrouped) 的
        // 浅灰底形成断层 → 顶部出现一条明显的"白条"；深色模式下同理（黑 vs 深灰）。
        // iOS 26 液态玻璃 tab bar 是模糊材质，下层用什么色它就显什么色，
        // 所以这里只需要把 MainTabView 根 background 设为同色（已在 MainTabView 处理），
        // tab bar 那边自然跟上，不会再出现底部白条。
        bootstrapNavBarAppearance()
    }

    /// 全局 UINavigationBarAppearance 兜底：让所有 NavigationStack 的 nav bar
    /// 都铺上 systemGroupedBackground，根除顶部"白条"。
    private func bootstrapNavBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .systemGroupedBackground
        // shadow 设为透明避免在大标题切换时露出一道分隔线
        appearance.shadowColor = .clear
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .environmentObject(playerCore)
                .environmentObject(playerService)
                .environmentObject(settingsManager)
                .preferredColorScheme(settingsManager.appTheme.colorScheme)
                .task {
                    // 恢复已导入的自定义音源并重新激活
                    await WellLXSourceStore.shared.bootstrapIfNeeded()
                }
        }
    }
}