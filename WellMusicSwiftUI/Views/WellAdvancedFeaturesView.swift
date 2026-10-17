import SwiftUI

/// 高级功能页（2026-10-16 用户问题3）：
/// 「高级功能不是分组是一个入口 —— 点击进去之后才是高级功能的设置，包括分组啥的」。
/// 设置页里只有一行入口，本页收纳全部高级设置（音源族 + 更新策略）。
struct WellAdvancedFeaturesView: View {

    var body: some View {
        Form {
            Section {
                Toggle("内置音源", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: MusicURLResolver.builtinSourceKey) },
                    set: { UserDefaults.standard.set($0, forKey: MusicURLResolver.builtinSourceKey) }
                ))
                NavigationLink {
                    WellLXSourceTestView()
                } label: {
                    Label("音源测试", systemImage: "stethoscope")
                }
            } header: {
                Text("音源")
            } footer: {
                Text("开启「内置音源」后，未导入自定义音源（或全部音源解析失败）时，自动通过第三方解析获取完整音频（含 320k 高码率）。受版权限制的个别歌曲解析不到时回退官方通道（可能仅试听 30 秒）——这类歌可导入自定义音源解决。")
                    .font(.system(size: 12))
            }

            // ★ 2026-10-16 用户：内置音源提醒可由用户关闭
            Section {
                Toggle("内置音源播放提醒", isOn: Binding(
                    get: { (UserDefaults.standard.object(forKey: MusicURLResolver.builtinReminderKey) as? Bool) ?? true },
                    set: { UserDefaults.standard.set($0, forKey: MusicURLResolver.builtinReminderKey) }
                ))
            } header: {
                Text("提醒")
            } footer: {
                Text("关闭后，内置音源接管播放时不再弹出「使用内置音源播放」提示。")
                    .font(.system(size: 12))
            }

            // ★ 2026-10-16 用户问题4：启动应用时自动检查音源更新；
            //   可自动更新替换本地脚本；都能关。
            Section {
                Toggle("启动时自动检查更新", isOn: Binding(
                    get: { (UserDefaults.standard.object(forKey: WellLXSourceUpdateConfig.autoCheckUpdateKey) as? Bool) ?? true },
                    set: { UserDefaults.standard.set($0, forKey: WellLXSourceUpdateConfig.autoCheckUpdateKey) }
                ))
                Toggle("启动时执行音源自检", isOn: Binding(
                    get: { (UserDefaults.standard.object(forKey: WellLXSourceUpdateConfig.autoSelfCheckKey) as? Bool) ?? true },
                    set: { UserDefaults.standard.set($0, forKey: WellLXSourceUpdateConfig.autoSelfCheckKey) }
                ))
                Toggle("自动更新（直接替换本地脚本）", isOn: Binding(
                    get: { (UserDefaults.standard.object(forKey: WellLXSourceUpdateConfig.autoApplyUpdateKey) as? Bool) ?? false },
                    set: { UserDefaults.standard.set($0, forKey: WellLXSourceUpdateConfig.autoApplyUpdateKey) }
                ))
            } header: {
                Text("音源更新")
            } footer: {
                Text("每次启动应用时逐个音源在线比对版本。发现新版本：开「自动更新」直接覆盖本地脚本；关则弹窗提示，可在弹窗里一键更新。单个音源也可在「自定义音源」里单独关闭更新提示。")
                    .font(.system(size: 12))
            }
        }
        .navigationTitle("高级功能")
        .navigationBarTitleDisplayMode(.inline)
    }
}
