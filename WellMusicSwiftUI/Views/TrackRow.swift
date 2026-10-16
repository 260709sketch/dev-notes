import SwiftUI

/// 通用歌曲行（46 封面 + 歌名/歌手 + 右侧箭头）。
///
/// 原先与「音乐库」页（`FavoritesView`）同文件；2026-10-14 用户要求删除音乐库页，
/// 而本行被多个页面（我喜欢 / 听歌排行 / 最近播放 / 自建歌单详情…）共用，故独立成文件。
struct TrackRow: View {
    @EnvironmentObject private var appState: AppState
    let item: MusicItem
    /// ★ 2026-10-16 问题8：当前播放行显示音条动画（低频订阅，见 NowPlayingTracker）
    @ObservedObject private var nowPlaying = NowPlayingTracker.shared

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: item.albumCoverURL, size: 46, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(nowPlaying.isCurrent(item) ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(item.artist ?? "未知艺术家")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if nowPlaying.isNowPlaying(item) {
                NowPlayingIndicator()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
