import SwiftUI
import Combine

/// 正在播放跟踪器（2026-10-16 用户问题8）：
/// 「歌单、我的页面最近喜欢、专辑……同一首歌同一个平台都没有正在播放的标识，
/// 学习 Apple Music 和 Spotify」。
///
/// ⚠️ 性能铁律：**绝不让行视图直接订阅 PlayerCore**（`currentTime` 是 20Hz 广播）。
/// 本类只订阅 `currentIndex` / `isPlaying` 这两个**低频**发布器，
/// 且值不变不发布 —— 换歌/暂停那一下才让可见的行重算一次 body。
@MainActor
final class NowPlayingTracker: ObservableObject {

    static let shared = NowPlayingTracker()

    /// 当前播放曲目的 `keyOf`（含平台 + id + 歌手，天然满足「同歌同平台」比对）
    @Published private(set) var playingKey: String?
    @Published private(set) var isPlaying: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let core = PlayerCore.shared
        func refresh() {
            let key: String? = core.currentIndex.flatMap { index in
                core.queue.indices.contains(index) ? core.queue[index].keyOf : nil
            }
            if playingKey != key { playingKey = key }
            if isPlaying != core.isPlaying { isPlaying = core.isPlaying }
        }
        core.$currentIndex.sink { _ in refresh() }.store(in: &cancellables)
        core.$isPlaying.sink { _ in refresh() }.store(in: &cancellables)
    }

    /// 该行是否要显示「正在播放」标识（当前曲目且正在播放）。
    func isNowPlaying(_ item: MusicItem) -> Bool {
        isPlaying && playingKey == item.keyOf
    }

    /// 该行是否是「当前曲目」（含暂停态 —— 标题着色用）。
    func isCurrent(_ item: MusicItem) -> Bool {
        playingKey == item.keyOf
    }
}

/// Apple Music / Spotify 风格的三根音条动画（仅在**当前播放行**渲染，体积 16×14pt）。
///
/// ★ 2026-10-16 第十轮问题15：暂停后音条不再直接消失（改为静止状态）——
///   行侧「时长/音条」位不会变空；恢复播放继续动。
struct NowPlayingIndicator: View {
    // ★ 2026-10-16 用户：「时长旁会动的图标还是红色」→ 改蓝
    var color: Color = Color(red: 0.25, green: 0.52, blue: 0.96)

    @ObservedObject private var tracker = NowPlayingTracker.shared
    @State private var animating = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            bar(ratio: 0.5, delay: 0)
            bar(ratio: 1.0, delay: 0.18)
            bar(ratio: 0.7, delay: 0.36)
        }
        .frame(width: 16, height: 14, alignment: .bottom)
        .onAppear { animating = true }
    }

    private func bar(ratio: CGFloat, delay: Double) -> some View {
        Capsule()
            .fill(color)
            .frame(width: 3, height: 14 * ratio)
            .scaleEffect(y: (animating && tracker.isPlaying) ? 0.4 : 1.0, anchor: .bottom)
            .animation(
                .easeInOut(duration: 0.45)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: animating
            )
    }
}
