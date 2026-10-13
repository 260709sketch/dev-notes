import SwiftUI

/// 搜索页设计常量（对齐 kumone 版式）
enum WellSearchMetrics {
    static let contentInset: CGFloat = 16
    static let cardSize: CGFloat = 156
    static let artistSize: CGFloat = 118
    /// 歌曲行封面尺寸（对照 kumone：手机上 48pt 圆角小方图）
    static let trackArtwork: CGFloat = 48
    static let trackRowHeight: CGFloat = 64
}

// MARK: - 搜索框

/// 搜索输入框（对照 kumone 截图）：浅灰圆角胶囊 + 放大镜 + 占位文案 + 清除按钮。
///
/// 单独成组件而不是内联，是因为搜索页要把它放在 `NavigationStack` 的固定位置，
/// 并且右侧「取消」按钮只在激活时出现 —— 拆开后各页可复用。
struct WellSearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索歌曲、歌手、专辑、歌单"
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .focused(isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(AppTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 胶囊分段选择

/// 胶囊式分段控件（对照 kumone 截图）。
///
/// ⚠️ 不用系统 `.pickerStyle(.segmented)`：截图里选中项是**白底圆角胶囊 + 轻阴影**、
/// 未选中完全透明、分隔线极细 —— 系统分段控件的选中态是灰底填充，观感差距明显。
/// 这里自绘一个等宽分段的 HStack，选中项用 `matchedGeometryEffect` 让白胶囊平滑滑动。
struct WellSegmentedControl<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                let isSelected = item == selection
                Button {
                    guard item != selection else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        selection = item
                    }
                } label: {
                    Text(title(item))
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(.systemBackground))
                                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "wellSegIndicator", in: indicator)
                            }
                        }
                        .overlay(alignment: .leading) {
                            // 未选中项之间保留极细分隔线（首项除外、选中项两侧也不画）
                            if index > 0, !isSelected, items[index - 1] != selection {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(width: 0.5, height: 16)
                                    .offset(x: -0.25)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(AppTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - VIP 徽章

/// 红框红字的小胶囊（对照 kumone `VIPBadge`）。
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


// MARK: - 异步封面

/// 轻量异步图片（圆形/圆角自适应），带占位。
/// 走统一的 `WellImageCache`（两级缓存 + 防盗链头），替代裸 `AsyncImage`。
struct WellRemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    /// 卡片在屏幕上的点尺寸。给了就向图床要对应尺寸的缩图 ——
    /// 原图 1024×1024 解码就是 4 MB，货架里铺十几张足以把滚动拖垮。
    /// （2026-10-13 迁移：播放器评论头像用 `displaySize:` 调用，需当前版实现。）
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

/// 分区标题（对照 kumone 截图）：标题粗体 + 右侧小箭头（无「查看全部」字样）。
struct WellSectionHeader: View {
    let title: String
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 19, weight: .bold))
            Spacer()
            if let action {
                Button(action: action) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
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

// MARK: - 搜索歌曲行

/// 搜索结果歌曲行（对照 kumone 截图）：
/// `[封面 48] 歌名 + VIP徽章 / 歌手   ……   [红心] [时长]`
///
/// ⚠️ 收藏态单独抽成叶子视图 `WellSearchLikeButton`：它只订阅 `AccountStore`，
///    避免整个列表随播放/收藏变化重算（性能铁律：列表行不订阅 PlayerCore）。
struct WellSearchTrackRow: View {
    let item: MusicItem

    var body: some View {
        HStack(spacing: 12) {
            WellRemoteImage(url: item.albumCoverURL, displaySize: WellSearchMetrics.trackArtwork)
                .frame(width: WellSearchMetrics.trackArtwork, height: WellSearchMetrics.trackArtwork)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .medium))
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

            WellSearchLikeButton(item: item)

            Text(item.durationText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(height: WellSearchMetrics.trackRowHeight)
        .contentShape(Rectangle())
    }
}

/// 搜索行右侧收藏按钮（红心）。叶子视图，只订阅 `AppState`（原生吃 `MusicItem`，
/// 不经过桥接层 `Track` 转换）。
struct WellSearchLikeButton: View {
    let item: MusicItem

    @ObservedObject private var appState = AppState.shared

    private var isLiked: Bool { appState.isFavorite(item) }

    var body: some View {
        Button {
            appState.toggleFavorite(item)
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 15))
                .foregroundStyle(isLiked ? Color(red: 0.98, green: 0.30, blue: 0.35) : Color.secondary.opacity(0.55))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}