import SwiftUI
import UIKit

/// 应用级方向锁：全局默认竖屏，只有 MV 播放页临时放开横屏。
/// （Info.plist 声明了 Portrait + Landscape；实际旋转与否由这里返回的掩码决定。）
final class WellMusicAppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        WellMusicAppDelegate.orientationLock
    }
}

@main
struct WellMusicApp: App {
    @UIApplicationDelegateAdaptor(WellMusicAppDelegate.self) private var appDelegate
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
        // ★ 2026-10-16 问题15：
        //   ① 冷启动按「缓存上限」清一次超额缓存（含图片 / 歌曲 / 歌手主页缓存）——
        //      原先上限只在歌曲下载完成后才检查，用户「设置了 4G 依旧超过 4G」；
        //   ② 清掉历史版本遗留的歌词缓存目录（已废弃，且界面上已没有入口）。
        //   （`CacheBudget` 是主 actor 隔离的，这里显式跳到主 actor 上调用。）
        Task { @MainActor in
            CacheBudget.enforceIfNeeded(force: true)
        }
        Self.removeLegacyLyricCacheIfNeeded()
    }

    /// 删除历史版本遗留的歌词缓存目录（一次性）。
    ///
    /// 用户 2026-10-16 问题15：「把没用的歌词缓存移除」。界面入口与写入都已去掉，
    /// 这里把老版本留下的文件也一并清掉 —— 否则这部分空间用户再也无法释放。
    private static func removeLegacyLyricCacheIfNeeded() {
        let key = "wellmusic.cache.legacyLyricCacheCleaned"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent("amll-ttml", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        UserDefaults.standard.set(true, forKey: key)
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
                    // 启动恢复上次播放（设置里可开关；默认关）。恢复列表与位置，
                    // 播放地址会重新解析（不会用过期的音源链接）。
                    PlayerCore.shared.restorePlaybackIfNeeded()
                    // 启动时自动检查音源更新（2026-10-16 问题4；高级功能里可关）。
                    // 稍等几秒，别跟首屏网络与音源激活抢通道。
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await WellLXSourceStore.shared.runLaunchUpdateCheckIfNeeded()
                }
        }
    }
}