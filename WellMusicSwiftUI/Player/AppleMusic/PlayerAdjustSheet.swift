import SwiftUI

/// 播放器调整：集中放 Apple Music 播放页的观感微调。
///
/// 入口在播放页「三个点」菜单里的「播放器调整」，点开以 sheet 呈现。
/// 所有改动都是**即时生效**的 —— 直接写 `SettingsManager` 的 @AppStorage，
/// 拖滑块的同时背后的播放页就已经变了，不需要「应用」按钮。
///
/// 参数语义与取值区间对齐 Kumone 的对应设置组（顶部 50…400 / 底部 100…500 /
/// 左右 -200…200，单位均为**点**）。
struct PlayerAdjustSheet: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                backgroundSection
                amllLyricSection
                amllFontSection
            }
            .navigationTitle("播放器调整")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - 背景

    private var backgroundSection: some View {
        Section {
            Toggle("流体渐变背景", isOn: fluidBackgroundBinding)

            Picker("背景模式", selection: backgroundModeBinding) {
                ForEach(AppleMusicBackgroundMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // 背景暗度：调的是盖在背景层之上的那块遮罩。
            // 暗色模式下 0 = 不压暗（背景最亮），1 = 几乎全黑；
            // 浅色模式下则是提亮遮罩的强度。
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("背景暗度")
                    Spacer()
                    Text("\(Int((settings.appleMusicBackgroundDim * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: backgroundDimBinding, in: 0...1, step: 0.02)
            }
        } header: {
            Text("背景")
        } footer: {
            Text("流体渐变按 AMLL 最新版的效果实现：封面取色 + 四色流体，极低分辨率渲染、省电；关闭则退回封面模糊。觉得背景太亮就把暗度调高。")
        }
    }

    // MARK: - AMLL 歌词位置

    private var amllLyricSection: some View {
        Section {
            pixelSlider(
                title: "歌词顶部位置",
                value: topBinding,
                range: 50...400,
                note: "越大歌词整体越靠下"
            )
            pixelSlider(
                title: "歌词底部位置",
                value: bottomBinding,
                range: 100...500,
                note: "底部留白，避免压到底部控制栏"
            )
            pixelSlider(
                title: "歌词左右位置",
                value: horizontalBinding,
                range: -200...200,
                note: "正值两侧留白更多，负值歌词更宽"
            )
        } header: {
            Text("AMLL 歌词位置")
        } footer: {
            Text(settings.appleMusicUseAMLL
                 ? "单位为点（pt），改动即时生效。"
                 : "当前未开启 AMLL 歌词，这些设置会在开启后生效。")
        }
    }

    // MARK: - AMLL 歌词字体（大小 / 字重）

    private var amllFontSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("歌词大小")
                    Spacer()
                    Text("\(Int(settings.appleMusicAmllFontSize))pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: fontSizeBinding,
                    in: 16...48,
                    step: 1
                )
            }

            Picker("歌词字重", selection: fontWeightBinding) {
                Text("中等").tag(500)
                Text("半粗").tag(600)
                Text("粗体").tag(700)
                Text("特粗").tag(800)
                Text("极粗").tag(900)
            }
        } header: {
            Text("AMLL 歌词字体")
        } footer: {
            Text(settings.appleMusicUseAMLL
                 ? "大小与字重改动即时生效于歌词页。"
                 : "当前未开启 AMLL 歌词，这些设置会在开启后生效。")
        }
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { settings.appleMusicAmllFontSize },
            set: { settings.appleMusicAmllFontSize = $0 }
        )
    }

    private var fontWeightBinding: Binding<Int> {
        Binding(
            get: { settings.appleMusicAmllFontWeight },
            set: { settings.appleMusicAmllFontWeight = $0 }
        )
    }

    // MARK: - 绑定
    //
    // 一律走显式的 `Binding(get:set:)`，不用 `$settings.xxx`。
    // `SettingsManager` 上这些是 `@AppStorage`，直接取 `$settings.xxx` 依赖
    // 属性包装器的 keypath 推断，在部分 Xcode 版本上会报「无法推断类型」。
    // 显式构造没有这个风险，且写入行为完全一致（都落到同一处 UserDefaults）。

    private var backgroundModeBinding: Binding<AppleMusicBackgroundMode> {
        Binding(
            get: { settings.appleMusicBackgroundMode },
            set: { settings.appleMusicBackgroundMode = $0 }
        )
    }

    private var fluidBackgroundBinding: Binding<Bool> {
        Binding(
            get: { settings.appleMusicFluidBackground },
            set: { settings.appleMusicFluidBackground = $0 }
        )
    }

    private var backgroundDimBinding: Binding<Double> {
        Binding(
            get: { settings.appleMusicBackgroundDim },
            set: { settings.appleMusicBackgroundDim = $0 }
        )
    }

    private var topBinding: Binding<Int> {
        Binding(
            get: { settings.appleMusicAmllLyricTop },
            set: { settings.appleMusicAmllLyricTop = $0 }
        )
    }

    private var bottomBinding: Binding<Int> {
        Binding(
            get: { settings.appleMusicAmllLyricBottom },
            set: { settings.appleMusicAmllLyricBottom = $0 }
        )
    }

    private var horizontalBinding: Binding<Int> {
        Binding(
            get: { settings.appleMusicAmllLyricHorizontal },
            set: { settings.appleMusicAmllLyricHorizontal = $0 }
        )
    }

    // MARK: - 组件

    /// 整数点位滑块。
    ///
    /// `@AppStorage` 里位置是 `Int`，而 `Slider` 只接受 `Double`，
    /// 所以这里做一层往返绑定；`step` 用 5 让点位落在 5 的倍数上好记。
    private func pixelSlider(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 5
            )
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
