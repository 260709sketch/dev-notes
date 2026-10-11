#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// 液态玻璃底部栏：底部栏普通毛玻璃 + 选中项液态玻璃药丸（点击/长按抬起效果）
struct WellGlassTabBar: View {
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
    @EnvironmentObject private var settings: SettingsManager

    /// Finger x (in content space) while actively dragging the pill; nil at rest.
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
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    // 关键：只在 selection 真正变化时动画，且用 id 固定身份避免重建。
                    // 之前这里没有稳定 id，切换 tab 时 SwiftUI 会销毁重建整个 ZStack
                    // （含 CGPath 阴影与液态玻璃底），造成“抖一下”。
                    .animation(settle, value: selection)

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
        .background { WellGlassBackground(config: settings.liquidGlassConfig, contentScaleFactor: 0.3, isPaused: false) }
        .overlay {
            Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.08 : 0.22),
                                   lineWidth: 0.5)
        }
        .clipShape(Capsule())
        // 阴影固定几何，不再随 selection 变化重算 —— 消除切换时的重绘抖动
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }

    private func itemLabel(_ item: WellGlassTabBar.Item) -> some View {
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

    /// The sliding indicator — a bar-height capsule with faint tint.
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
                if !isDragging && abs(value.translation.width) < 8 { return }
                isDragging = true
                dragX = value.location.x
                let tab = items[index(for: value.location.x, cellW: cellW, count: count)].tab
                if tab != selection { selection = tab }
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

/// 液态玻璃背景：用 UIViewRepresentable 包装液态玻璃效果
struct WellGlassBackground: UIViewRepresentable {
    var style: WellGlassEffect.Style = .regular
    var config: WellGlassConfig? = nil
    var contentScaleFactor: CGFloat = 1.0  // 降低渲染分辨率提升性能
    var isPaused: Bool = false  // 暂停渲染循环（静态背景模式下使用）

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        let glassView = createGlassView()
        glassView.frame = container.bounds
        glassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(glassView)
        context.coordinator.glassView = glassView
        context.coordinator.container = container

        // 监听全局滑动状态——只调帧率和分辨率，不重建视图
        let coordinator = context.coordinator
        context.coordinator.cancellable = WellScrollDetector.shared.$isScrolling
            .receive(on: DispatchQueue.main)
            .sink { [weak coordinator] scrolling in
                coordinator?.updatePerformance(isScrolling: scrolling)
            }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // isPaused 变化时直接更新，不重建
        context.coordinator.externalPaused = isPaused
        if let glassView = context.coordinator.glassView as? WellGlassEffectView {
            glassView.isPaused = isPaused
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentScaleFactor: contentScaleFactor, config: config)
    }

    final class Coordinator {
        weak var glassView: UIView?
        weak var container: UIView?
        var cancellable: AnyCancellable?
        let contentScaleFactor: CGFloat
        let config: WellGlassConfig?
        var externalPaused = false

        init(contentScaleFactor: CGFloat, config: WellGlassConfig?) {
            self.contentScaleFactor = contentScaleFactor
            self.config = config
        }

        /// 滑动时直接暂停渲染，停止后恢复——完全避免滑动卡顿
        func updatePerformance(isScrolling: Bool) {
            guard let glassView else { return }
            if let effectView = glassView as? WellGlassEffectView {
                effectView.isPaused = isScrolling || externalPaused
                if !isScrolling {
                    let baseFps = config?.preferredFramesPerSecond ?? 40
                    effectView.wellGlassView?.preferredFramesPerSecond = baseFps
                }
            }
            if !isScrolling {
                glassView.contentScaleFactor = max(0.1, contentScaleFactor)
            }
        }
    }

    private func createGlassView() -> UIView {
        let view: UIView
        let baseFps = config?.preferredFramesPerSecond ?? 40

        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: style.nativeStyle)
            view = UIVisualEffectView(effect: effect)
        } else {
            let effect: WellGlassEffect
            if let config = config {
                effect = WellGlassEffect(customWellGlass: config.toWellGlass)
            } else {
                effect = WellGlassEffect(style: style, isNative: false)
            }
            let glassView = WellGlassEffectView(effect: effect, preferredFramesPerSecond: baseFps)
            glassView.isPaused = isPaused
            view = glassView
        }
        view.contentScaleFactor = max(0.1, contentScaleFactor)
        return view
    }
}
#endif