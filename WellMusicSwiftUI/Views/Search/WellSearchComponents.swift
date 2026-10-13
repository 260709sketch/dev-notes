import SwiftUI

/// 搜索页设计常量（对齐 kumone 版式）
enum WellSearchMetrics {
    static let contentInset: CGFloat = 16
    static let cardSize: CGFloat = 156
    static let artistSize: CGFloat = 118
}

// MARK: - 异步封面

/// 轻量异步图片（圆形/圆角自适应），带占位。
/// 走统一的 `WellImageCache`（两级缓存 + 防盗链头），替代裸 `AsyncImage`。
struct WellRemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    /// 卡片在屏幕上的点尺寸。给了就向图床要对应尺寸的缩图 ——
    /// 原图 1024×1024 解码就是 4 MB，货架里铺十几张足以把滚动拖垮。
    var displaySize: CGFloat?

    private var resolvedURL: URL? {
        WellArtworkURL.resolved(url, pixelSize: displaySize.map(WellArtworkURL.pixelSize(forPoints:)))
    }

    var body: some View {
        WellAsyncImage(url: resolvedURL) {
            ZStack {
                AppTheme.secondaryBackground
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 分区标题

struct WellSectionHeader: View {
    let title: String
    /// 可选的副标题：发现页用它做「编辑精选」式的说明（如「根据你的口味」）。
    var subtitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let action {
                Button(action: action) {
                    HStack(spacing: 2) {
                        Text("查看全部")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 横向货架

struct WellShelf<Content: View>: View {
    let title: String
    /// 可选副标题（发现页的编辑式说明），透传给分区标题。
    var subtitle: String?
    var action: (() -> Void)?
    /// 提供时用 `LazyHStack` + 固定行高（kumone Shelf 同款：卡片懒创建，
    /// 竖向滚动时只实例化可视卡片）。nil 时退回普通 `HStack`。
    var rowHeight: CGFloat?
    @ViewBuilder var content: () -> Content

    private let spacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WellSectionHeader(title: title, subtitle: subtitle, action: action)
                .padding(.horizontal, WellSearchMetrics.contentInset)
            ScrollView(.horizontal, showsIndicators: false) {
                cards
                    .padding(.vertical, 4)
            }
            // 刻意**不加** `.scrollClipDisabled()`：关掉裁剪会让滚动时画面外的内容
            // 也参与渲染，横向滑动明显更吃性能；本项目的卡片没有外发光/外阴影，
            // 不需要靠关裁剪来露出来。
        }
    }

    // ⚠️ Lazy 栈只有在**外层给了固定行高**时才能安全使用（交叉轴可测）；
    // 这正是 kumone Shelf 传 rowHeight 的原因 —— 懒加载与不塌陷兼得。
    @ViewBuilder
    private var cards: some View {
        if let rowHeight {
            LazyHStack(alignment: .top, spacing: spacing) {
                edgeInset
                content()
                edgeInset
            }
            .frame(height: rowHeight)
        } else {
            HStack(alignment: .top, spacing: spacing) {
                edgeInset
                content()
                edgeInset
            }
        }
    }

    private var edgeInset: some View {
        Color.clear.frame(width: max(0, WellSearchMetrics.contentInset - spacing), height: 1)
    }
}

// MARK: - 卡片上浮进场动画（kumone StaggeredAppearance 同款行为，代码原创）

/// 卡片首次滚入可视区时从下方 16pt 上浮 + 淡入；同一张卡只播一次
/// （`AnimationCache` 按 itemID 去重，防止来回滚动反复动画）。
private enum WellCardEntranceCache {
    nonisolated(unsafe) static var animated = Set<String>()

    static func hasAnimated(_ key: String) -> Bool { animated.contains(key) }

    static func markAnimated(_ key: String) {
        if animated.count > 600 { animated.removeAll() }
        animated.insert(key)
    }
}

struct WellCardEntrance: ViewModifier {
    let index: Int
    let itemID: String

    @State private var isVisible = false

    private static let staggerDelay = 0.04
    private static let maxStaggerDelay = 0.4

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 16)
            .onAppear {
                guard !WellCardEntranceCache.hasAnimated(itemID) else {
                    isVisible = true
                    return
                }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)
                    .delay(min(Double(index) * Self.staggerDelay, Self.maxStaggerDelay))) {
                    isVisible = true
                }
                WellCardEntranceCache.markAnimated(itemID)
            }
    }
}

// MARK: - 自适应网格

struct WellCardGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder var content: () -> Content

    private var columns: [GridItem] {
        if sizeClass == .regular {
            return [GridItem(.adaptive(minimum: WellSearchMetrics.cardSize, maximum: WellSearchMetrics.cardSize + 40),
                             spacing: 18, alignment: .top)]
        }
        return [GridItem(.flexible(), spacing: 14, alignment: .top),
                GridItem(.flexible(), spacing: 14, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            content()
        }
    }
}

// MARK: - 封面卡片（专辑 / 歌单）

struct WellCoverCard: View {
    let coverURL: String?
    let title: String
    var subtitle: String?
    var playCount: Int = 0
    var size: CGFloat = WellSearchMetrics.cardSize
    /// 网格中使用：铺满所在列宽（货架中保持固定尺寸）
    var fillWidth: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                artwork
                if playCount > 0 {
                    WellPlayCountBadge(count: playCount)
                        .padding(6)
                }
            }
            .modifier(WellCardSizeModifier(size: size, fillWidth: fillWidth))

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
        .modifier(WellCardSizeModifier(size: size, fillWidth: fillWidth))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var artwork: some View {
        let base = WellRemoteImage(url: coverURL, displaySize: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        if fillWidth {
            base.aspectRatio(1, contentMode: .fit)
        } else {
            base.frame(width: size, height: size)
        }
    }
}

// MARK: - 歌手卡片（圆形）

struct WellArtistCard: View {
    let artist: WellArtistSummary
    var size: CGFloat = WellSearchMetrics.artistSize
    var fillWidth: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            artwork
            Text(artist.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let subtitle = artist.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(WellCardSizeModifier(size: size + 12, fillWidth: fillWidth))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var artwork: some View {
        let base = WellRemoteImage(url: artist.picURL, displaySize: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        if fillWidth {
            base.aspectRatio(1, contentMode: .fit)
        } else {
            base.frame(width: size, height: size)
        }
    }
}

/// 卡片尺寸：网格铺满列宽 / 货架固定宽度
private struct WellCardSizeModifier: ViewModifier {
    let size: CGFloat
    let fillWidth: Bool

    func body(content: Content) -> some View {
        if fillWidth {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content.frame(width: size, alignment: .leading)
        }
    }
}

// MARK: - 播放量角标

struct WellPlayCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
            Text(playCountText)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.35), in: Capsule())
    }

    private var playCountText: String {
        if count >= 100_000_000 { return String(format: "%.1f亿", Double(count) / 100_000_000) }
        if count >= 10_000 { return String(format: "%.1f万", Double(count) / 10_000) }
        return "\(count)"
    }
}
// MARK: - 以下为 2026-10-13 晚新增组件（每日推荐页等使用；搜索页本体仍用上方 11:10 原版组件）

/// 红框红字的小胶囊 VIP 徽章。
struct WellVipBadge: View {
    var body: some View {
        Text("VIP")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color(red: 0.90, green: 0.20, blue: 0.24))
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color(red: 0.90, green: 0.20, blue: 0.24), lineWidth: 1)
            )
    }
}

/// 歌曲行（封面56 / 歌名+VIP / 歌手 / 红心·仅收藏显示 / 时长）。
struct WellSearchTrackRow: View {
    let item: MusicItem

    @ObservedObject private var appState = AppState.shared

    var body: some View {
        HStack(spacing: 12) {
            WellRemoteImage(url: item.albumCoverURL, displaySize: 56)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if item.isVip {
                        WellVipBadge()
                    }
                }
                Text(item.artist ?? "未知歌手")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if appState.isFavorite(item) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(red: 0.98, green: 0.30, blue: 0.35))
            }

            Text(item.durationText)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(minHeight: 68)
        .contentShape(Rectangle())
    }
}
