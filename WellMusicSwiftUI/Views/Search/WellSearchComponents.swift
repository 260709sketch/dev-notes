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

    private var resolvedURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        return URL(string: url)
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
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 19, weight: .bold))
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
    var action: (() -> Void)?
    @ViewBuilder var content: () -> Content

    private let spacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WellSectionHeader(title: title, action: action)
                .padding(.horizontal, WellSearchMetrics.contentInset)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    Color.clear.frame(width: WellSearchMetrics.contentInset - spacing, height: 1)
                    content()
                    Color.clear.frame(width: WellSearchMetrics.contentInset - spacing, height: 1)
                }
                .padding(.vertical, 4)
            }
            .modifier(WellScrollClipModifier())
        }
    }
}

/// iOS 17+ 允许内容溢出滚动裁剪
private struct WellScrollClipModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollClipDisabled()
        } else {
            content
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
            ZStack(alignment: .topTrailing) {
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
        let base = WellRemoteImage(url: coverURL)
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
        let base = WellRemoteImage(url: artist.picURL)
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