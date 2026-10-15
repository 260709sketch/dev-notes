import SwiftUI

/// 均衡器页（10 段倍频程 + 预置 + 自定义预设）。
///
/// 布局：启用开关 → 预置横滑 chips → 10 段滑条 → 保存为预设 / 我的预设。
/// 增益实时下发播放内核（MPV lavfi 音频滤镜链）。
struct WellEqualizerView: View {
    @ObservedObject private var equalizer = WellEqualizer.shared
    @State private var showingSavePreset = false
    @State private var presetName = ""

    var body: some View {
        Form {
            Section {
                Toggle("启用均衡器", isOn: Binding(
                    get: { equalizer.isEnabled },
                    set: { equalizer.setEnabled($0) }
                ))
            }

            if equalizer.isEnabled {
                Section("预置") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(EQPreset.allCases) { preset in
                                presetChip(preset)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("频段") {
                    ForEach(0..<WellEqualizer.bandFrequencies.count, id: \.self) { index in
                        HStack(spacing: 12) {
                            Text(freqLabel(WellEqualizer.bandFrequencies[index]))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { equalizer.bandGains[index] },
                                    set: { equalizer.setBandGain(at: index, to: $0) }
                                ),
                                in: -WellEqualizer.maximumGain...WellEqualizer.maximumGain,
                                step: 0.5
                            )
                            Text(gainLabel(equalizer.bandGains[index]))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }

                Section {
                    Button {
                        presetName = ""
                        showingSavePreset = true
                    } label: {
                        Label("保存为预设", systemImage: "square.and.arrow.down")
                    }
                }

                if !equalizer.customPresets.isEmpty {
                    Section("我的预设") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(equalizer.customPresets) { preset in
                                    HStack(spacing: 4) {
                                        Button {
                                            equalizer.applyCustomPreset(preset)
                                        } label: {
                                            Text(preset.name)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(AppTheme.accent.opacity(0.18), in: Capsule())
                                        }
                                        .buttonStyle(.plain)

                                        Button(role: .destructive) {
                                            equalizer.deleteCustomPreset(preset)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .navigationTitle("均衡器")
        .alert("保存预设", isPresented: $showingSavePreset) {
            TextField("预设名称", text: $presetName)
            Button("保存") {
                equalizer.saveCustomPreset(name: presetName)
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func presetChip(_ preset: EQPreset) -> some View {
        Button {
            equalizer.applyPreset(preset)
        } label: {
            Text(preset.displayName)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    equalizer.selectedPreset == preset ? AppTheme.accent : AppTheme.secondaryBackground,
                    in: Capsule())
                .foregroundStyle(equalizer.selectedPreset == preset ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func freqLabel(_ freq: Double) -> String {
        if freq >= 1000 {
            return String(format: "%.0fk", freq / 1000)
        }
        return String(format: "%.0f", freq)
    }

    private func gainLabel(_ gain: Double) -> String {
        String(format: "%+.1f dB", gain)
    }
}
