import SwiftUI
import UIKit
import MediaPlayer
import QuartzCore

// MARK: - 全局帧率监视（诊断用）

/// 常驻 CADisplayLink 只做「帧计数」，不驱动任何渲染 —— 开销可忽略。
/// 供「播放诊断」页与悬浮 FPS 徽章读取滚动窗口帧率（2026-10-14 掉帧排查）。
final class FPSMonitor: NSObject, ObservableObject {
    static let shared = FPSMonitor()

    /// 最近约 1 秒滚动窗口内的帧率。
    @Published private(set) var fps: Int = 0

    private var link: CADisplayLink?
    private var frameTimes: [CFTimeInterval] = []

    private override init() {
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        frameTimes.append(now)
        while let first = frameTimes.first, now - first > 1.0 {
            frameTimes.removeFirst()
        }
        if frameTimes.count != fps {
            fps = frameTimes.count
        }
    }
}

// MARK: - 播放诊断页

/// 控制中心 / 掉帧问题的一次性排查面板（2026-10-14）。
///
/// 目的：把「控制中心不显示」「掉帧」整条链路的**真实运行值**摊开 ——
/// 音频会话类别/选项、NowPlaying 是否真的写入了系统、远程命令启用状态、
/// 会话守卫自愈次数、实时帧率 —— 用户截一张图即可定位断点，不再盲修。
///
/// ⚠️ 本页是排障工具，**允许**订阅 PlayerCore（20Hz）；离开即销毁，不影响其它页面。
struct WellPlayerDiagnosticsView: View {
    @ObservedObject private var player = PlayerCore.shared
    @ObservedObject private var fpsMonitor = FPSMonitor.shared

    /// 非 @Published 的会话值按 1s 节拍复读。
    @State private var refreshTick = Date()

    /// 悬浮 FPS 徽章开关（显示在 App 右上角，便于在全页面观察帧率）。
    @AppStorage("wellmusic.debug.fpsOverlay") private var fpsOverlay = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("帧率") {
                HStack {
                    Text("当前帧率")
                    Spacer()
                    Text("\(fpsMonitor.fps) fps")
                        .monospacedDigit()
                        .foregroundStyle(fpsMonitor.fps >= 55 ? .green : (fpsMonitor.fps >= 40 ? .orange : .red))
                }
                Toggle("右上角悬浮帧率", isOn: $fpsOverlay)
                Text("滚动/切页时观察此数字；哪一页掉到 40 以下请在反馈里告诉我。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("音频会话") {
                diagRow("类别 category", session.category.rawValue)
                diagRow("模式 mode", session.mode.rawValue)
                diagRow("选项 options", "\(session.categoryOptions.rawValue)")
                diagRow("其它音频在播", session.isOtherAudioPlaying ? "是" : "否")
                diagRow("输出延迟", String(format: "%.0f ms", player.outputLatency * 1000))
            }

            Section("控制中心 / NowPlaying") {
                diagRow("已写入系统", MPNowPlayingInfoCenter.default().nowPlayingInfo == nil ? "❌ 未写入" : "✅ 已写入")
                diagRow("歌名", (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String) ?? "—")
                diagRow("播放速率 rate", String(format: "%.1f", (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double) ?? -1))
                diagRow("playbackState", playbackStateText)
            }

            Section("远程命令（控制中心按钮）") {
                let commands = MPRemoteCommandCenter.shared()
                diagRow("播放键启用", commands.playCommand.isEnabled ? "✅" : "❌")
                diagRow("暂停键启用", commands.pauseCommand.isEnabled ? "✅" : "❌")
                diagRow("下一首启用", commands.nextTrackCommand.isEnabled ? "✅" : "❌")
                diagRow("播放/暂停切换键", commands.togglePlayPauseCommand.isEnabled ? "✅" : "❌")
            }

            Section("会话守卫（类别自愈）") {
                diagRow("自愈次数", "\(player.sessionGuardHealCount) 次")
                diagRow("最近一次", player.lastSessionGuardHealAt.map { ago(from: $0) } ?? "从未")
                Text("若次数持续增长，说明有组件（mpv 音频输出）在反复改跑会话类别。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("播放状态") {
                diagRow("有活跃曲目", player.hasActiveTrack ? "是" : "否")
                diagRow("正在播放", player.isPlaying ? "是" : "否")
                diagRow("音频在渲染", player.isRenderingAudio ? "是" : "否")
                diagRow("位置", String(format: "%.1f s", player.currentTime))
            }
        }
        .navigationTitle("播放诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(ticker) { refreshTick = $0 }
    }

    // MARK: - 取值

    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    private var playbackStateText: String {
        switch MPNowPlayingInfoCenter.default().playbackState {
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        @unknown default: return "unknown"
        }
    }

    private func diagRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func ago(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds) 秒前" }
        return "\(seconds / 60) 分钟前"
    }
}

// MARK: - 悬浮帧率徽章

/// 右上角小徽章（`wellmusic.debug.fpsOverlay` 开启时显示于 MainTabView 顶层）。
struct FPSBadge: View {
    @ObservedObject private var fpsMonitor = FPSMonitor.shared

    var body: some View {
        Text("\(fpsMonitor.fps) FPS")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .allowsHitTesting(false)
    }
}

#Preview {
    NavigationStack { WellPlayerDiagnosticsView() }
}
