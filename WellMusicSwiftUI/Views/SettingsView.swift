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
