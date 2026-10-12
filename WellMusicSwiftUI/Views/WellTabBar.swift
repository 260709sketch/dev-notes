import SwiftUI

/// WellMusic 底部 Tab 枚举
///
/// ⚠️ `title` 必须与底栏实际显示的文案一致（见 `MainTabView.glassTabItems`
/// 与 `iOS26TabView` 的 `Tab(...)` 标签）。之前出现过 `navigationTitle`
/// 与底栏文案对不上的问题（底栏写「发现」，导航大标题却写「电台」），
/// 排查时极易误判为「切页标题跳动」。改文案时三处要一起改。
enum WellTab: String, CaseIterable, Identifiable {
    case favorites
    case profile
    case radio
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "音乐库"
        case .profile: return "我的"
        case .radio: return "主页"
        case .search: return "搜索"
        }
    }

    var icon: String {
        switch self {
        case .favorites: return "square.grid.2x2"
        case .profile: return "person.crop.circle"
        case .radio: return "house"
        case .search: return "magnifyingglass"
        }
    }
}

#if os(iOS)
import UIKit

/// 浮动底部栏 (iOS 16–25 无原生液态玻璃)，模型参考 Telegram 的
/// `TabBarComponent` / `LiquidLensView`：
///   • 全高玻璃胶囊（56pt 内容 + 4pt 内边距 = 64pt），接近全宽；
///   • 滑动选择的胶囊填满栏高，采用 Telegram 的浅色调暗 —
///     浅色黑 @ 7.5% / 深色白 @ 10%，不是亮色块；
///   • 23pt 填充图标 + 10pt 半粗标签共用一色：未选中黑 @ 80%，选中主题色；
///   • 可拖动的交互胶囊：手指跟着切换 tab，松手后弹簧回位；轻点直接滑动。
struct WellTabBar: View {
    struct Item: Identifiable {
        let tab: WellTab
        let title: LocalizedStringKey
        let icon: String
        var id: WellTab { tab }
    }

    let items: [Item]
    @Binding var selection: WellTab
    var onReselect: (WellTab) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    /// 拖动胶囊时手指 x（内容空间坐标）；静止时为 nil。
    @State private var dragX: CGFloat?
    @State private var isDragging = false

    private let innerInset: CGFloat = 4
    private let contentHeight: CGFloat = 56
    private let settle = Animation.spring(response: 0.35, dampingFraction: 0.82)

    var body: some View {
        GeometryReader { geo in
            let count = max(items.count, 1)
            let cellW = geo.size.width / CGFloat(count)
            let selectedIndex = items.firstIndex { $0.tab == selection } ?? 0
            let restX = cellW * (CGFloat(selectedIndex) + 0.5)
            let pillX = isDragging
                ? min(max(dragX ?? restX, cellW / 2), geo.size.width - cellW / 2)
                : restX

            ZStack(alignment: .leading) {
                selectionPill
                    .frame(width: cellW - 8, height: contentHeight)
                    .position(x: pillX, y: geo.size.height / 2)

                HStack(spacing: 0) {
                    ForEach(items) { item in
                        itemLabel(item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(cellW: cellW, count: count))
        }
        .frame(height: contentHeight)
        .padding(innerInset)
        .background { Capsule().fill(.regularMaterial) }
        .overlay {
            Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0.22),
                                   lineWidth: 0.5)
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }

    private func itemLabel(_ item: WellTabBar.Item) -> some View {
        let isSelected = selection == item.tab
        return VStack(spacing: 3) {
            Image(systemName: item.icon)
                .font(.system(size: 23, weight: .semibold))
                .symbolVariant(.fill)
            Text(item.title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(isSelected
                         ? AnyShapeStyle(Theme.accent)
                         : AnyShapeStyle(Color.primary.opacity(0.8)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// 滑动指示器 —— 栏高胶囊 + Telegram 式浅色调。
    private var selectionPill: some View {
        Capsule(style: .continuous)
            .fill(colorScheme == .dark
                  ? Color.white.opacity(0.10)
                  : Color.black.opacity(0.075))
    }

    private func index(for x: CGFloat, cellW: CGFloat, count: Int) -> Int {
        min(max(Int(x / cellW), 0), count - 1)
    }

    private func dragGesture(cellW: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 等待清晰的横向意图再“抬起”胶囊，
                // 让轻点表现为滑动而不是瞬移到手指位置。
                if !isDragging && abs(value.translation.width) < 8 { return }
                isDragging = true
                dragX = value.location.x
                let tab = items[index(for: value.location.x, cellW: cellW, count: count)].tab
                if tab != selection { selection = tab }   // live switch, pill tracks finger
            }
            .onEnded { value in
                let tab = items[index(for: value.location.x, cellW: cellW, count: count)].tab
                if isDragging {
                    withAnimation(settle) { selection = tab; dragX = nil }
                } else if tab == selection {
                    onReselect(tab)
                } else {
                    withAnimation(settle) { selection = tab }
                }
                isDragging = false
            }
    }
}
#endif