import SwiftUI
import MediaPlayer
import UIKit

// MARK: - Apple Music V2 弹性滑块
//
// 严格对照参考源码 `WellMusicAppleMusicV2Player.tsx` 里两处 `<Slider>`（进度条 / 音量条）：
// - 轨道高度 7pt，拖动时 withTiming(15, 160ms out-cubic)，松手 220ms 回落到 7pt；
// - `sliderHeight={7}`、`thumbWidth={12}`，圆角恒为 8（全圆）；
// - 圆点（renderThumb）平时 opacity 0、4×4 透明，拖动时 opacity 1 且 `withSpring(2)` 放大；
// - 点击可跳转（`disableTapEvent={false}`）；拖动中排除外部时钟回写（`isProgressSliding`）。

struct AppleMusicV2Slider: View {
    /// 当前值（0...1）
    @Binding var value: Double
    /// 拖动开始回调（对应 `onSlidingStart`）
    var onSlidingStart: () -> Void = {}
    /// 拖动中回调（对应 `onValueChange`）
    var onValueChange: (Double) -> Void = { _ in }
    /// 拖动结束回调（对应 `onSlidingComplete`）
    var onSlidingComplete: (Double) -> Void = { _ in }
    /// 轨道两端的额外留白（进度条 0、音量条由外层 margin 控制）
    var showsThumb = true

    @State private var dragging = false
    @State private var dragFraction: Double = 0

    private var fraction: Double {
        min(max(dragging ? dragFraction : value, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let trackH = dragging ? AppleMusicV2.Controls.trackHeightActive : AppleMusicV2.Controls.trackHeight
            let filled = width * CGFloat(fraction)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AppleMusicV2.Controls.trackBackground)
                    .frame(height: trackH)

                Capsule(style: .continuous)
                    .fill(AppleMusicV2.Controls.trackTint)
                    .frame(width: max(0, filled), height: trackH)

                if showsThumb {
                    // 拖动圆点：平时透明不可见，拖动时放大到 2 倍
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .scaleEffect(dragging ? 2 : 1)
                        .opacity(dragging ? 1 : 0)
                        .offset(x: filled - 6)
                        .animation(AppleMusicV2.Motion.thumbSpring, value: dragging)
                }
            }
            .frame(height: AppleMusicV2.Controls.trackHeightActive, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging {
                            dragging = true
                            dragFraction = value
                            onSlidingStart()
                        }
                        let ratio = Double(min(max(gesture.location.x / width, 0), 1))
                        dragFraction = ratio
                        onValueChange(ratio)
                    }
                    .onEnded { gesture in
                        let ratio = Double(min(max(gesture.location.x / width, 0), 1))
                        dragFraction = ratio
                        dragging = false
                        onSlidingComplete(ratio)
                    }
            )
            .animation(
                dragging ? AppleMusicV2.Motion.trackExpand : AppleMusicV2.Motion.trackCollapse,
                value: dragging
            )
        }
        .frame(height: AppleMusicV2.Controls.trackHeightActive)
    }
}

// MARK: - 进度条（含三栏时间 + 中央音质胶囊）

struct AppleMusicV2ProgressSection: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var core = PlayerCore.shared

    private var total: Double {
        max(max(player.duration, player.currentTrack?.duration ?? 0), 1)
    }

    /// 播放位置：拖动中由 PlayerCore.scrubTime 提供（clock 已统一走 displayTime），
    /// 松手后由精确 seek 完成、isScrubbing 复位，自动回落到真实时间。
    private var displayTime: Double {
        clock.progress
    }

    /// 剩余时间：参考源码 `-formatTime(duration > 0 && currentTime < duration ? max(1, duration - currentTime) : 0)`
    private var remaining: Double {
        guard total > 0, displayTime < total else { return 0 }
        return max(1, total - displayTime)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppleMusicV2Slider(
                value: Binding(
                    get: { total > 0 ? min(max(displayTime / total, 0), 1) : 0 },
                    set: { _ in }
                ),
                onSlidingStart: {
                    // 关键：进入 scrubbing 态，PlayerCore.displayTime 立刻切到 scrubTime，
                    // 从而歌词页 / AMLL / 进度条三处同时跟随手指。
                    core.beginScrubbing(to: clock.progress)
                },
                onValueChange: { ratio in
                    // 拖动中持续写入预览位置（50ms 时钟会把它同步给所有消费方）
                    core.updateScrubbing(to: ratio * total)
                },
                onSlidingComplete: { ratio in
                    // 精确 seek（tolerance .zero）并在完成后复位 isScrubbing
                    core.endScrubbing(to: ratio * total)
                }
            )

            // `styles.progressTimeRow { marginTop: 12 }`：左当前 / 中音质 / 右剩余
            HStack(spacing: 0) {
                Text(wellamTimeString(displayTime))
                    .frame(maxWidth: .infinity, alignment: .leading)

                qualityBadge
                    .frame(maxWidth: .infinity)

                Text("-" + wellamTimeString(remaining))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: AppleMusicV2.Controls.timeFontSize, weight: .medium))
            .foregroundStyle(AppleMusicV2.Controls.timeColor)
            .padding(.top, AppleMusicV2.Controls.progressTimeTop)
        }
    }

    /// `styles.qualityBadge`：波形图标 + 档位名，点击可切档（对应参考源码 MenuView 音质菜单）
    private var qualityBadge: some View {
        Menu {
            ForEach(WellAudioQuality.allCases) { quality in
                Button {
                    changeQuality(quality)
                } label: {
                    if quality == appState.audioQuality {
                        Label("\(quality.displayName) · \(quality.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(quality.displayName) · \(quality.detail)")
                    }
                }
            }
        } label: {
            HStack(spacing: AppleMusicV2.Controls.qualityBadgeSpacing) {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                Text(appState.audioQuality.badgeText)
                    .font(.system(size: AppleMusicV2.Controls.qualityBadgeFontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, AppleMusicV2.Controls.qualityBadgeHPadding)
            .padding(.vertical, AppleMusicV2.Controls.qualityBadgeVPadding)
            .background(AppleMusicV2.Controls.qualityBadgeFill, in: RoundedRectangle(cornerRadius: AppleMusicV2.Controls.qualityBadgeRadius, style: .continuous))
            .padding(.top, AppleMusicV2.Controls.qualityBadgeTopMargin)
        }
        .buttonStyle(.plain)
    }

    /// 切音质：记录当前进度 → 用新档位重载当前曲目 → 回到原进度（对应参考源码 handleQualityChange）
    private func changeQuality(_ quality: WellAudioQuality) {
        guard quality != appState.audioQuality else { return }
        let resume = clock.progress
        let core = PlayerCore.shared
        appState.audioQuality = quality

        guard let item = core.currentItem, let index = core.currentIndex else { return }
        core.play(queue: core.queue, startIndex: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            core.seek(to: resume)
        }
    }
}

// MARK: - 音量条（`styles.volumeRow`）

struct AppleMusicV2VolumeRow: View {
    @EnvironmentObject private var player: PlayerService
    @State private var localValue: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: AppleMusicV2.Controls.volumeIconSmallSize))
                .foregroundStyle(AppleMusicV2.Controls.volumeIconColor)
                .frame(width: 16, alignment: .leading)

            AppleMusicV2Slider(
                value: Binding(
                    get: { Double(player.volume) },
                    set: { localValue = $0 }
                ),
                onValueChange: { ratio in
                    localValue = ratio
                },
                onSlidingComplete: { ratio in
                    player.volume = Float(ratio)
                }
            )
            .padding(.horizontal, AppleMusicV2.Controls.volumeSliderMargin)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: AppleMusicV2.Controls.volumeIconLargeSize))
                .foregroundStyle(AppleMusicV2.Controls.volumeIconLargeColor)
                .frame(width: 20, alignment: .trailing)
        }
    }
}

// MARK: - AirPlay 路由按钮（对应参考源码 `AirPlayRoutePicker`）
//
// 参考源码用 `MPVolumeView` 的 `showsRouteButton` 提供系统 AirPlay 面板，这里同样走 UIKit。

struct AirPlayRouteButton: UIViewRepresentable {
    var iconSize: CGFloat = AppleMusicV2.Controls.bottomButtonIconSize
    var tint: UIColor = UIColor(white: 0.851, alpha: 1)

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsVolumeSlider = false
        view.showsRouteButton = true
        view.tintColor = tint
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.tintColor = tint
        uiView.showsVolumeSlider = false
    }
}
