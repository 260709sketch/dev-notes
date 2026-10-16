import SwiftUI

/// 播放器调整：集中放 Apple Music 播放页的观感微调。
///
/// 入口在播放页「三个点」菜单里的「播放器调整」，点开以 sheet 呈现。
/// 所有改动都是**即时生效**的 —— 位置类直接写 `AppleMusicLayoutStore`，
/// 其它写 `SettingsManager` 的 @AppStorage，拖滑块的同时背后的播放页就已经变了。
///
/// 分组（2026-10-13 扩展，对齐 RN `PlayerLayoutScreen.tsx`）：
///  * 位置调整：大封面 / 歌手歌曲信息（含字号）/ 播放进度条 / 控制中心（整体）/
///    音量条 / 底部按钮，全部支持上下（歌手信息另支持左右）；
///  * 外观：背景（流体渐变 / 模式 / 暗度）、顶部小横条隐藏；
///  * 歌词：AMLL 位置 + 字体，另含歌词页歌曲名/歌手字号。
struct PlayerAdjustSheet: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var layout = AppleMusicLayoutStore.shared

    var body: some View {
        NavigationStack {
            Form {
                positionSection
                trackInfoFontSection
                lyricsHeaderSection
                backgroundSection
                topBarSection
                amllLyricSection
                lyricAlignmentSection
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

    // MARK: - 位置调整（上下，单位 pt）

    private var positionSection: some View {
        Section {
            // 大封面位置（上下）
            layoutSlider(
                title: "大封面位置",
                part: .cover,
                axis: .vertical,
                range: -200...200,
                note: "调整大封面整体上下位置"
            )
            // 播放进度条（上下）
            layoutSlider(
                title: "播放进度条位置",
                part: .progress,
                axis: .vertical,
                range: -100...200,
                note: "调整进度条整体上下位置"
            )
            // 控制中心（上一首/播放/下一首 整体，上下）
            controlsSlider
            // 音量条（上下）
            layoutSlider(
                title: "音量条位置",
                part: .volume,
                axis: .vertical,
                range: -100...200,
                note: "调整音量条整体上下位置"
            )
            // 评论区 / 歌词入口 / 播放列表（上下）
            layoutSlider(
                title: "底部按钮位置",
                part: .actions,
                axis: .vertical,
                range: -100...200,
                note: "评论区、歌词入口、播放列表整体上下位置"
            )
        } header: {
            Text("位置调整")
        } footer: {
            Text("单位为点（pt），改动即时生效。负值向上、正值向下。")
        }
    }

    /// 歌手歌曲信息：上下左右 + 字号（需求 11/12）
    private var trackInfoFontSection: some View {
        Section {
            layoutSlider(
                title: "歌手歌曲信息 上下",
                part: .title,
                axis: .vertical,
                range: -200...200,
                note: "歌曲名/歌手信息整体上下位置"
            )
            layoutSlider(
                title: "歌手歌曲信息 左右",
                part: .title,
                axis: .horizontal,
                range: -200...200,
                note: "正值向右、负值向左"
            )
            fontSizeSlider(
                title: "歌曲名字号",
                key: "wellmusic.appleMusic.trackTitleFontSize",
                defaultValue: 22,
                range: 12...40
            )
            fontSizeSlider(
                title: "歌手信息字号",
                key: "wellmusic.appleMusic.trackArtistFontSize",
                defaultValue: 13.5,
                range: 9...28
            )
        } header: {
            Text("歌手歌曲信息")
        } footer: {
            Text("字号同时作用于大封面状态与歌词页顶部的歌曲名 / 歌手信息。")
        }
    }

    /// 歌词页顶部整行 + 歌名歌手单独位置。
    ///
    /// * `.lyricsHeader`    → 小封面 + 歌名歌手 + 五角星 + 三点**整体**上下
    /// * `.lyricsTrackInfo` → 其中的歌名/歌手文字块**单独**上下左右
    ///
    /// 与大封面状态的那行（`trackInfoFontSection` 用 `.title`）完全独立，
    /// 调这里不会影响大封面。
    private var lyricsHeaderSection: some View {
        Section {
            layoutSlider(
                title: "歌词页顶部整行 上下",
                part: .lyricsHeader,
                axis: .vertical,
                range: -200...200,
                note: "小封面 / 歌名歌手 / 五角星 / 三点 整体上下"
            )
            layoutSlider(
                title: "歌词页歌名歌手 上下",
                part: .lyricsTrackInfo,
                axis: .vertical,
                range: -100...100,
                note: "仅歌词页顶部的歌名 / 歌手文字块"
            )
            layoutSlider(
                title: "歌词页歌名歌手 左右",
                part: .lyricsTrackInfo,
                axis: .horizontal,
                range: -100...100,
                note: "正值向右、负值向左"
            )
        } header: {
            Text("歌词页顶部")
        } footer: {
            Text("仅作用于歌词页（小封面那一行），不影响大封面状态。")
        }
    }

    /// 「控制中心」：上一首 / 播放 / 下一首整体上下（需求 15，不分开调整）
    private var controlsSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("控制中心位置")
                Spacer()
                Text("\(Int(layout.controlsY.rounded()))pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(layout.controlsY) },
                    set: { layout.setControlsY(CGFloat($0.rounded())) }
                ),
                in: -100...200,
                step: 1
            )
            Text("上一首 / 播放 / 下一首三个按钮整体上下位置")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
        }
    }

    // MARK: - 顶部小横条

    private var topBarSection: some View {
        Section {
            Toggle("隐藏顶部小横条", isOn: hideTopIndicatorBinding)
        } header: {
            Text("顶部")
        } footer: {
            Text("隐藏大封面状态顶部用于下滑关闭的横条指示器（手势仍可用）。")
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

    // MARK: - 歌词对齐（2026-10-16 用户问题11：iOS 原生分段控制）

    private var lyricAlignmentSection: some View {
        Section {
            Picker("歌词对齐", selection: Binding(
                get: { settings.appleMusicLyricAlignment },
                set: { settings.appleMusicLyricAlignment = $0 }
            )) {
                Text("居中").tag(0)
                Text("左").tag(1)
                Text("右").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("歌词位置")
        } footer: {
            Text("歌词行在页面内的对齐方向（居中 / 靠左 / 靠右）。")
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

    // MARK: - 绑定

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

    /// 顶部小横条隐藏开关（存 SettingsManager 的 @AppStorage）
    private var hideTopIndicatorBinding: Binding<Bool> {
        Binding(
            get: { settings.appleMusicHideTopIndicator },
            set: { settings.appleMusicHideTopIndicator = $0 }
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

    /// 布局偏移滑块（上下 / 左右），作用于 `AppleMusicLayoutStore`。
    private enum Axis { case vertical, horizontal }

    private func layoutSlider(
        title: String,
        part: AppleMusicLayoutPart,
        axis: Axis,
        range: ClosedRange<Int>,
        note: String
    ) -> some View {
        let current: CGFloat = axis == .vertical ? layout.entry(for: part).y : layout.entry(for: part).x
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(current.rounded()))pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(current) },
                    set: { newValue in
                        var entry = layout.entry(for: part)
                        if axis == .vertical {
                            entry.y = CGFloat(newValue.rounded())
                        } else {
                            entry.x = CGFloat(newValue.rounded())
                        }
                        layout.set(entry, for: part)
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 字号滑块：直接写 UserDefaults（播放页用 @AppStorage 镜像实时刷新）。
    private func fontSizeSlider(
        title: String,
        key: String,
        defaultValue: Double,
        range: ClosedRange<Double>
    ) -> some View {
        let binding = Binding<Double>(
            get: {
                let v = UserDefaults.standard.double(forKey: key)
                return v == 0 ? defaultValue : v
            },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(binding.wrappedValue.rounded()))pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: binding, in: range, step: 1)
        }
    }

    /// 整数点位滑块（作用于 SettingsManager 的 Int @AppStorage）。
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
