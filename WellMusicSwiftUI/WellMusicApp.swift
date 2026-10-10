import SwiftUI

@main
struct WellMusicApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var playerCore = PlayerCore.shared

    init() {
        // 配置音频会话：后台播放 + 耳机/锁屏控制
        AudioSessionManager.configure()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .environmentObject(playerCore)
                .preferredColorScheme(.dark)
        }
    }
}