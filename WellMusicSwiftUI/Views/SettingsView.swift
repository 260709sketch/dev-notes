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

    @State private var showingQualitySheet = false

    /// 底部栏位置微调的文案（正 = 更靠下）。
    private var tabBarOffsetText: String {
        let value = settings.tabBarBottomOffset
        if abs(value) < 0.5 { return "默认" }
        return value > 0 ? "靠下 \(Int(value))pt" : "靠上 \(Int(-value))pt"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("音频") {
                    // 「播放音质」：点击弹出小卡片选择，不再是整页跳转（需求 22）
                    Button {
                        showingQualitySheet = true
                    } label: {
                        HStack {
                            Text("播放音质")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(appState.audioQuality.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("断开蓝牙自动暂停", isOn: $settings.bluetoothAutoPause)
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

                    // 底部栏（dock + 迷你播放器）纵向位置自由微调（2026-10-14 用户要求）
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("底部栏位置")
                            Spacer()
                            Text(tabBarOffsetText)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.tabBarBottomOffset, in: -20...24, step: 2)
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
            .sheet(isPresented: $showingQualitySheet) {
                QualitySelectorSheet()
                    .environmentObject(appState)
            }
        }
    }
}

#Preview {
    SettingsView()
}
