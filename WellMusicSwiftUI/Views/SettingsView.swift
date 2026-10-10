import SwiftUI

/// 设置页：含核心的「歌词来源」与逐字歌词开关
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

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
                    Picker("播放模式", selection: $appState.playMode) {
                        Text("列表循环").tag(0)
                        Text("单曲循环").tag(1)
                        Text("随机播放").tag(2)
                    }
                    .pickerStyle(.navigationLink)

                    Toggle("高音质优先（无损）", isOn: $appState.highQuality)
                    Toggle("交叉淡入淡出", isOn: $appState.crossfade)
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