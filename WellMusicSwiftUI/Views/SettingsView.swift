import SwiftUI

/// 设置页：含核心的「歌词来源」与逐字歌词开关
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lxStore = WellLXSourceStore.shared

    /// 自定义液态玻璃配置的绑定
    private var customGlass: Binding<WellGlassConfig> {
        Binding(
            get: { settings.customLiquidGlassConfig },
            set: { settings.customLiquidGlassConfig = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("歌词") {
                    Picker("歌词来源", selection: Binding(
                        get: { appState.lyricSource },
                        set: { appState.setLyricSource($0) }
                    )) {
                        Text("自动").tag(MusicSource.auto)
                        Text("QQ音乐").tag(MusicSource.qq)
                        Text("网易云音乐").tag(MusicSource.netease)
                        Text("酷狗音乐").tag(MusicSource.kugou)
                        Text("酷我音乐").tag(MusicSource.kuwo)
                    }
                    .pickerStyle(.navigationLink)

                    Toggle("逐字歌词（卡拉OK）", isOn: $appState.karaokeEnabled)
                    Text("切歌后按上方来源获取歌词；逐字歌词优先展示，其次逐行 LRC。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(value: Binding(
                        get: { Int(appState.lyricOffset * 1000) },
                        set: { appState.lyricOffset = Double($0) / 1000 }
                    ), in: -1000...1000, step: 50) {
                        HStack {
                            Text("歌词同步偏移")
                            Spacer()
                            Text("\(Int(appState.lyricOffset * 1000)) ms")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Text("正值=高亮提前，负值=延后。用于校准歌词与歌声的残余偏差。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("播放") {
                    Picker("播放器样式", selection: $settings.nowPlayingMode) {
                        ForEach(NowPlayingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Picker("播放模式", selection: $appState.playMode) {
                        Text("列表循环").tag(0)
                        Text("单曲循环").tag(1)
                        Text("随机播放").tag(2)
                    }
                    .pickerStyle(.navigationLink)

                    Toggle("高音质优先（无损）", isOn: $appState.highQuality)
                    Toggle("交叉淡入淡出", isOn: $appState.crossfade)
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

                    Picker("底部栏样式", selection: $settings.tabBarStyle) {
                        ForEach(WellTabBarStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Text("iOS 26 及以上自动使用系统液态玻璃渲染；旧版本使用自研兼容渲染。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.tabBarStyle == .liquidGlass {
                        Picker("液态玻璃预设", selection: $settings.liquidGlassPreset) {
                            ForEach(WellGlassPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.navigationLink)

                        if settings.liquidGlassPreset == .custom {
                            Group {
                                Slider(value: customGlass.tintOpacity, in: 0...1) {
                                    Text("色调透明度")
                                }
                                Slider(value: customGlass.blurRadius, in: 0...1) {
                                    Text("背景模糊")
                                }
                                Slider(value: customGlass.glassThickness, in: 0...20) {
                                    Text("玻璃厚度")
                                }
                                Slider(value: customGlass.refractiveIndex, in: 1.0...2.0) {
                                    Text("折射率")
                                }
                                Slider(value: customGlass.dispersionStrength, in: 0...30) {
                                    Text("色散强度")
                                }
                            }
                            .font(.caption)
                        }
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