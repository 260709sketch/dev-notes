import SwiftUI

// MARK: - 搜索页版式常量
//
// ★ 2026-10-14 用户第四轮需求：搜索页在「搜索之后」的版式（5 张实机截图）。
//
// 这里的每一个数值都是**按实机截图逐像素量出来的**，不是估的：
//   * `contentInset`  = 24
//     （实机截图 IMG_3968 量得的歌曲封面左缘 = 54px @2.252× = **24.0pt**，吻合）
//   * `cardSize`      = 160
//   * `cardRadius`    = 8
//   * `rowArtwork`    = 48
//   * `rowHeight`     = 64
//
// ⚠️ 为什么另起一套组件、而不是改 `WellCoverCard` / `WellArtistCard` / `WellCardGrid` /
//   `WellShelf` / `WellSectionHeader`？因为它们**同时被发现页 / 精选页 / 我的页 /
//   每日推荐页 / 歌手主页共用**。用户只要求搜索页按这套版式对齐，直接改公共组件会
//   顺带改掉那几个已经定版（且逐像素校准过）的页面 —— 属于「乱加」。
//   本文件里的组件只服务 `SearchView`。
enum WellSearchLayout {
    static let contentInset: CGFloat = 24
    static let cardSize: CGFloat = 160
    static let cardRadius: CGFloat = 8
    static let rowArtwork: CGFloat = 48
    static let rowHeight: CGFloat = 64
}

// MARK: - 分区标题

/// `.title2.weight(.semibold)` 标题 + **紧跟标题**的 chevron（不是右侧「查看全部」）。
/// `action` 非空时整块可点 —— 搜索页综合 tab 的「单曲 ›」「歌手 ›」就是这一种。
struct WellSearchSectionHeader: View {
    let title: String
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
                    .font(.title2.weight(.semibold))
            }
            Spacer()
        }
    }
}

// MARK: - 横向货架

/// 卡片间距 16 / 分区上下留白 6 / 货架内部垂直间距 14；
/// 左右首尾各垫一段「不足 24 的差额」，让首卡与页面 24pt 内边距对齐。
struct WellSearchShelf<Content: View>: View {
    let title: String
    var seeAll: (() -> Void)?
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WellSearchSectionHeader(title: title, action: seeAll)
                .padding(.horizontal, WellSearchLayout.contentInset)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    edgeInset
                    content()
                    edgeInset
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var edgeInset: some View {
        Color.clear.frame(width: max(0, WellSearchLayout.contentInset - spacing), height: 1)
    }
}

// MARK: - 封面卡片（专辑 / 歌单）

/// 封面 160×160 r8 + 播放量角标**贴右上角**（不是右下）
/// + 标题 13pt medium 两行 + 副标题 11pt secondary 一行。
struct WellSearchCoverCard: View {
    let coverURL: String?
    let title: String
    var subtitle: String?
    var playCount: Int = 0

    private var size: CGFloat { WellSearchLayout.cardSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                WellRemoteImage(url: coverURL, displaySize: size)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: WellSearchLayout.cardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: WellSearchLayout.cardRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                if playCount > 0 {
                    WellPlayCountBadge(count: playCount)
                        .padding(6)
                }
            }
            .frame(width: size, height: size)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 歌手卡片（圆形）

/// 圆形头像 128 + 名字 13pt medium，**没有副标题** ——
/// 对齐实机截图 IMG_3969（歌手 tab 每张卡只有头像 + 名字）。
struct WellSearchArtistCard: View {
    let artist: WellArtistSummary

    private var size: CGFloat { 128 }

    var body: some View {
        VStack(spacing: 10) {
            WellRemoteImage(url: artist.picURL, displaySize: size)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            Text(artist.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(width: size + 12)
        .contentShape(Rectangle())
    }
}

// MARK: - 自适应网格

/// 紧凑宽度（iPhone）= **两列等宽**（列间距 16 / 行间距 20）；
/// 常规宽度（iPad）= `adaptive(160...200)`（列间距 20 / 行间距 24）。
struct WellSearchCardGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder var content: () -> Content

    private var isCompact: Bool { sizeClass == .compact }

    private var columns: [GridItem] {
        if isCompact {
            return [GridItem(.flexible(), spacing: 16, alignment: .top),
                    GridItem(.flexible(), spacing: 16, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: WellSearchLayout.cardSize,
                                   maximum: WellSearchLayout.cardSize + 40),
                         spacing: 20, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: isCompact ? 20 : 24) {
            content()
        }
    }
}

// MARK: - 歌曲行

/// 封面 48 r6 + 歌名 16pt medium + 歌手 13pt secondary + 右侧（红心·仅收藏时 + 时长）。
///
/// ⚠️ 与 `TrackRow`（46 封面 + 右侧 chevron）**不是同一个组件**：本列表行
///   右侧显示的是**时长**、没有 chevron，红心只在已收藏时出现（iOS 无 hover 态）。
///   之前搜索页误用了公共 `TrackRow`，所以看起来和截图不一样。
struct WellSearchSongRow: View {
    let item: MusicItem

    @ObservedObject private var appState = AppState.shared
    /// ★ 2026-10-16 问题8：当前播放行显示音条动画（低频订阅，见 NowPlayingTracker）
    @ObservedObject private var nowPlaying = NowPlayingTracker.shared

    var body: some View {
        HStack(spacing: 12) {
            WellRemoteImage(url: item.albumCoverURL, displaySize: WellSearchLayout.rowArtwork)
                .frame(width: WellSearchLayout.rowArtwork, height: WellSearchLayout.rowArtwork)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(nowPlaying.isCurrent(item) ? Color.accentColor : .primary)
                    .lineLimit(1)
                Text(item.artist ?? "未知歌手")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if appState.isFavorite(item) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.98, green: 0.30, blue: 0.35))
                }
                if nowPlaying.isCurrent(item) {
                    NowPlayingIndicator()
                } else {
                    Text(item.durationText)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: WellSearchLayout.rowHeight)
        .contentShape(Rectangle())
    }
}

/// 歌曲列表容器：`LazyVStack(spacing: 1)`，**没有分隔线**。
struct WellSearchSongList: View {
    let tracks: [MusicItem]
    let onPlay: (Int) -> Void
    /// 触底回调：列表尾部哨兵进入渲染窗口时调用（搜索页单曲「下滑自动补齐」用）。
    /// ⚠️ 哨兵带 `id(tracks.count)`：每补一页重建一次，若仍在视口内会继续补齐
    /// （直到内容超过一屏自然滚出视口，或调用方判定没有更多）。
    var onReachEnd: (() -> Void)?

    var body: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, item in
                Button {
                    onPlay(index)
                } label: {
                    WellSearchSongRow(item: item)
                }
                .buttonStyle(.plain)
            }
            if let onReachEnd {
                Color.clear
                    .frame(height: 1)
                    .id(tracks.count)
                    .onAppear { onReachEnd() }
            }
        }
    }
}
