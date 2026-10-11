import SwiftUI

/// 设置页。
///
/// 精简原则：只保留用户真正会调的项。逐字歌词、歌词来源、交叉淡入淡出等已改为内部默认行为
/// （见 AppState），播放模式 / 歌词偏移移到播放器界面的菜单里，底部栏样式与播放器样式不再暴露。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
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
