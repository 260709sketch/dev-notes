import SwiftUI

/// 设置页。
///
/// 精简原则：只保留用户真正会调的项。逐字歌词、歌词来源、交叉淡入淡出等已改为内部默认行为
/// （见 AppState），播放模式 / 歌词偏移移到播放器界面的菜单里，底部栏样式与播放器样式不再暴露。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var lxStore = WellLXSourceStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("音频") {
                    Picker("音质调节", selection: $appState.audioQuality) {
                        ForEach(WellAudioQuality.allCases) { quality in
                            HStack {
                                Label(quality.displayName, systemImage: quality.symbolName)
                                Spacer()
                                Text(quality.detail)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(quality)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Text("音质越高流量与加载耗时越大；若平台无对应档位资源，会自动回退到可用档位。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("断开蓝牙自动暂停", isOn: $settings.bluetoothAutoPause)
                    Text("断开蓝牙耳机或拔出耳机时自动暂停播放，避免声音突然外放。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Text("激活自定义音源后，所有歌曲（含网易云歌曲）优先通过自定义音源解析播放，不再走官方通道，网易云 VIP 将不生效；无损音质取决于音源脚本实际返回的质量。自定义音源解析失败时会自动回退官方通道。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("歌单") {
                    NavigationLink {
                        PlaylistImportView()
                    } label: {
                        Label("导入歌单", systemImage: "square.and.arrow.down.on.square")
                    }
                    Text("粘贴网易云 / QQ 音乐的歌单分享链接，整张歌单保存到本地。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("界面") {
                    Picker("主题", selection: $settings.appTheme) {
                        ForEach(WellAppTheme.allCases) { theme in
                            Label(theme.displayName, systemImage: theme.symbolName)
                                .tag(theme)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Text("「跟随系统」会随 iOS 外观设置自动切换深色/浅色。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("歌词背景") {
                    Picker("渲染方式", selection: $settings.amllBackgroundMode) {
                        ForEach(AMLLBackgroundMode.allCases) { mode in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.displayName)
                                Text(mode.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Text("流动背景会根据专辑封面取色生成缓慢流动的光斑。「模糊」档在其上叠加高斯模糊，观感更柔和，也更省电。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // 只有真正会渲染流动层时才需要画质档位
                    if settings.amllBackgroundMode == .blurFlow || settings.amllBackgroundMode == .flowing {
                        Picker("渲染质量", selection: $settings.amllBackgroundQuality) {
                            ForEach(AMLLBackgroundQuality.allCases) { quality in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(quality.displayName)
                                    Text(quality.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(quality)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        Text("流动背景是覆盖全屏的 GPU 着色器，档位直接作用于渲染器的帧率与渲染分辨率。老机型或低电量时建议选「省电」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0 (SwiftUI)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("数据存储")
                        Spacer()
                        Text("本地")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // ★ List 系统自带背景自动延伸到 chrome 区域下面（理由同 ProfileView），
            //   不写 scrollContentBackground / background，完全交给系统。
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
