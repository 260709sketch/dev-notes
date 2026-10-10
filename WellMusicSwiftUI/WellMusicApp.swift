import SwiftUI

@main
struct WellMusicApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var playerCore = PlayerCore.shared
    @StateObject private var playerService = PlayerService.shared
    @StateObject private var settingsManager = SettingsManager.shared

    init() {
        // 配置音频会话：后台播放 + 耳机/锁屏控制
        AudioSessionManager.configure()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .environmentObject(playerCore)
                .environmentObject(playerService)
                .environmentObject(settingsManager)
                .preferredColorScheme(.dark)
                .task {
                    // 恢复已导入的自定义音源并重新激活
                    await WellLXSourceStore.shared.bootstrapIfNeeded()
                }
        }
    }
}