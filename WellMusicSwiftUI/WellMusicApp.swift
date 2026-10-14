import SwiftUI

@main
struct WellMusicApp: App {
    /// ⚠️⚠️ 这里**只能**用 `@StateObject` 持有「参与 body 求值」的对象。
    ///
    /// 2026-10-14 16:44 掉帧根因（用户：「播放音乐就会掉帧严重」）：
    /// 原先 `playerCore` / `playerService` / `appState` 也写成了 `@StateObject`。
    /// `@StateObject` 的所有者会随对象**每次 publish 重算 body** —— 而
    /// `PlayerCore.currentTime` 播放期间是 **20Hz** 广播（暂停/空闲时去重不发）。
    /// 于是 App 根每秒重算 20 次、把整棵视图树重新 diff 20 次/秒。
    /// 这就是「一播放就掉帧」的开关：广播是否发生，等于音频是否在走。
    /// （项目铁律「绝不用 @EnvironmentObject 订阅 PlayerCore」在页面层执行得好，
    ///   唯独最外层漏了 —— 而最外层是代价最大的地方。）
    ///
    /// 正确做法：单例**直接注入**环境即可，注入不会订阅、不会让本结构重算。
    /// 只有 `settingsManager` 必须留在这里 —— 下面的 `preferredColorScheme` 要读它。
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
                // ⚠️ 单例直接注入：不要为了注入而把它们包成 @StateObject（见上方注释）。
                .environmentObject(AppState.shared)
                .environmentObject(PlayerCore.shared)
                .environmentObject(PlayerService.shared)
                .environmentObject(settingsManager)
                .preferredColorScheme(settingsManager.appTheme.colorScheme)
                .task {
                    // 恢复已导入的自定义音源并重新激活
                    await WellLXSourceStore.shared.bootstrapIfNeeded()
                }
        }
    }
}