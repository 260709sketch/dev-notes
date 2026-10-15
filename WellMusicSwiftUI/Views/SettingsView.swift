import SwiftUI

/// 设置页。
///
/// 精简原则（需求 21：彻底简化，简单设置不要说明）：只保留用户真正会调的项，
/// 去掉绝大多数解释性文字 —— 选项本身已足够自明。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lxStore = WellLXSourceStore.shared

    /// 底部栏位置微调的文案（正 = 更靠下）。
    private var tabBarOffsetText: String {
        let value = settings.tabBarBottomOffset
        if abs(value) < 0.5 { return "默认" }
        return value > 0 ? "靠下 \(Int(value))pt" : "靠上 \(Int(-value))pt"
    }

    var body: some View {
        NavigationStack {
            Form {
                // ★ 2026-10-14 用户：账号分组放在播放分组上面
                Section("账号") {
                    NavigationLink {
                        NeteaseAccountSettingsView()
                    } label: {
                        HStack {
                            Text("NetEase Cloud ID")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(NeteaseSession.shared.isLoggedIn ? "已登录" : "未登录")
                                .foregroundStyle(.secondary)
                        }
                    }
                    // ★ 2026-10-15 用户：「导入歌单」入口新增在此分组 ——
                    //   把原先「我的歌单」页右上角的「导入歌单 + 新建歌单」两个入口
                    //   合二为一（页内同时提供导入与新建）。
                    NavigationLink {
                        PlaylistImportView()
                    } label: {
                        Label("导入歌单", systemImage: "square.and.arrow.down")
                    }
                }

                Section("音频") {
                    // ★ 2026-10-14 用户：「设置播放音质点击之后要和三个点菜单弹窗一样」。
                    //   改成系统**原生下拉菜单**（Picker + .menu）：点一下直接弹出菜单，
                    //   不再走底部玻璃卡片 sheet。
                    Picker("播放音质", selection: $appState.audioQuality) {
                        ForEach(WellAudioQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("断开蓝牙自动暂停", isOn: $settings.bluetoothAutoPause)
                }

                Section("播放") {
                    // 启动恢复上次播放（2026-10-14 用户要求）
                    Toggle("启动恢复上次播放", isOn: $settings.restoreLastPlayback)
                    // 预加载下一首（2026-10-14 用户要求提供开关）
                    Toggle("预加载下一首", isOn: $settings.preloadNextEnabled)
                }

                Section("自定义音源") {
                    HStack {
                        Text("当前音源")
                        Spacer()
                        Text(lxStore.activeSource?.name ?? "未启用")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    NavigationLink {
                        WellLXSourceManageView()
                    } label: {
                        Label("管理自定义音源", systemImage: "square.stack.3d.up")
                    }
                    NavigationLink {
                        WellLXSourceStatusView()
                    } label: {
                        Label("音源状态", systemImage: "waveform.path.ecg")
                    }
                }

                Section("界面") {
                    Picker("主题", selection: $settings.appTheme) {
                        ForEach(WellAppTheme.allCases) { theme in
                            Label(theme.displayName, systemImage: theme.symbolName)
                                .tag(theme)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    // 发现页「每日推荐 / 私人漫游 / 心动模式」入口卡样式（2026-10-14）
                    Picker("发现页入口卡", selection: $settings.dailyCardStyle) {
                        ForEach(WellDailyCardStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    // 歌单封面样式（2026-10-14 用户设计稿：新版居中留白 / 旧版全宽铺满）
                    Picker("歌单封面样式", selection: $settings.playlistCoverStyle) {
                        ForEach(WellPlaylistCoverStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    // 底部栏（dock + 迷你播放器）纵向位置自由微调（2026-10-14 用户要求）
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("底部栏位置")
                            Spacer()
                            Text(tabBarOffsetText)
                                .foregroundStyle(.secondary)
                        }
                        // 行程 ±100pt（2026-10-14 16:50 用户要求，原 ±30 不够用）。
                        // ⚠️ 往下受基准限制：底部栏基准位置本身距屏幕底 42pt，
                        //    所以「靠下」的有效行程约 42pt（再往下会被屏幕底边裁掉）；
                        //    「靠上」100pt 完全有效（届时距底 ≈142pt）。
                        Slider(value: $settings.tabBarBottomOffset, in: -100...100, step: 2)
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0 (SwiftUI)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
