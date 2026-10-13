import SwiftUI

/// 播放音质选择弹窗（需求 22）。
///
/// 对齐 RN 版 `QualitySelector.tsx`：液态玻璃 Modal + 标题「选择音质」+
/// 逐项列出音质档位 + 选中项打勾。**不是**整页跳转，而是居中弹出的小卡片。
struct QualitySelectorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var options: [WellAudioQuality] { WellAudioQuality.allCases }

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 0) {
                Text("选择音质")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                VStack(spacing: 4) {
                    ForEach(options) { quality in
                        Button {
                            appState.audioQuality = quality
                            WellHaptics.tap()
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(quality.displayName)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(quality.detail)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if appState.audioQuality == quality {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(
                                appState.audioQuality == quality
                                    ? Color.primary.opacity(0.07)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
            .frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
            .padding(.horizontal, 32)
        }
        .presentationDetents([.height(300)])
        .presentationBackground(.clear)
        .presentationDragIndicator(.visible)
    }
}
