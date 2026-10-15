import SwiftUI

/// 「近期播放」—— 软件内**全部**播放记录的本地页（用户 2026-10-15）。
///
/// 数据纯本地（不拉网易云云端）：
/// * 歌曲段 = `AppState.playHistory`（含各平台来源，播放即记录）
/// * MV 段 = `AppState.mvHistory`（起播时埋点记录，见 `WellMVPlayerView`）
///
/// 顶部分段控制切「歌曲 / MV」；MV 段按用户要求**单竖列**摆放。
/// 歌曲段直接复用「我的」页经典歌单页版式（`WellMyPlaylistDetailView`）。
///
/// ⚠️ 性能铁律：不订阅 PlayerCore（20Hz 广播），只读 AppState 的两个历史数组。
struct LocalRecentPlaysView: View {
    @EnvironmentObject private var appState: AppState

    /// 分段：歌曲 / MV
    private enum Segment: String, CaseIterable, Identifiable {
        case songs = "歌曲"
        case mv = "MV"
        var id: String { rawValue }
    }

    @State private var segment: Segment = .songs
    /// 正在全屏播放的 MV（点 MV 行弹出）
    @State private var playingMV: WellMVSummary?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $segment) {
                ForEach(Segment.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 8)

            content
        }
        .navigationTitle("本地近期播放")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playingMV) { mv in
            WellMVPlayerView(mv: mv)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .songs:
            songsSegment
        case .mv:
            mvSegment
        }
    }

    /// 歌曲段：经典歌单页版式（与「我的歌单」页一致）。
    /// 传入的是进页快照 —— 与 `RecentPlaysView` 同语义。
    private var songsSegment: some View {
        Group {
            if appState.playHistory.isEmpty {
                ProfileEmptyTip(icon: "clock.arrow.circlepath",
                                title: "还没有播放记录",
                                note: "在 App 里播放歌曲后会出现在这里")
            } else {
                WellMyPlaylistDetailView(
                    source: .tracks(name: "近期播放",
                                    coverURL: appState.playHistory.first?.albumCoverURL,
                                    creatorName: nil,
                                    tracks: appState.playHistory))
            }
        }
    }

    /// MV 段：单竖列（一行一个，16:9 封面 + 名称/歌手/时长）。
    private var mvSegment: some View {
        Group {
            if appState.mvHistory.isEmpty {
                ProfileEmptyTip(icon: "film",
                                title: "还没有播放过 MV",
                                note: "在搜索页播放 MV 后会出现在这里")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(appState.mvHistory) { mv in
                            Button {
                                playingMV = mv
                            } label: {
                                mvRow(mv)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    // 底栏（迷你播放器 52 + 间距 8 + 胶囊栏 64 + 距底 42 = 166）留白
                    Color.clear.frame(height: 170)
                }
            }
        }
    }

    private func mvRow(_ mv: WellMVSummary) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                WellRemoteImage(url: mv.coverURL, displaySize: 320)
                    .frame(width: 128, height: 72)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("MV")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(mv.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Text(mv.artistName ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if mv.duration > 0 {
                    Text(Self.mvDurationText(mv.duration))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private static func mvDurationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    NavigationStack {
        LocalRecentPlaysView()
    }
}
