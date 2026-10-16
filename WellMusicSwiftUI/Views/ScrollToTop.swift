import SwiftUI

// MARK: - 回到顶部浮钮（2026-10-16 用户问题24）

/// 滚动偏移传递（PreferenceKey）。
/// ⚠️ 性能铁律：偏移**每帧**都在变，绝不能直接写进 @State（会让整页每帧重算）。
/// 这里只把值投给 `WellScrollToTopModifier` 的闭包，由它做**布尔翻转**判断 ——
/// 只有「显示/隐藏」状态真正变化时才写 @State。
struct WellScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 滚动偏移上报锚点（放在 ScrollView 内容**最顶部**）。
/// ⚠️ 2026-10-16 第十轮修复：探针必须挂在**内容**上 —— 之前直接挂在 ScrollView
/// 自身（background GeometryReader），测到的是不动的容器 → 偏移恒 0 → 浮钮永不出现
/// （用户原话「一键回顶的按钮在哪里」）。
struct WellScrollTopReporter: View {
    let space: String

    var body: some View {
        Color.clear
            .frame(height: 0)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: WellScrollOffsetKey.self,
                        value: -geo.frame(in: .named(space)).minY
                    )
                }
            )
    }
}

/// dock 栏上方的「回到顶部」浮钮：
/// * 上滑超过 400pt 且继续上滑 → 浮现；下滑 → 消失；接近顶部 → 消失；
/// * 浮现后 3.5 秒不点击自动消失（用户指定）。
struct WellScrollToTopModifier: ViewModifier {
    /// 浮钮距页面底部的距离（2026-10-16 用户：弄到迷你播放器上面一点）
    var bottomInset: CGFloat = 152
    let onScrollOffset: (CGFloat) -> Void

    @State private var visible = false
    @State private var lastOffset: CGFloat = 0
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if visible {
                    Button {
                        NotificationCenter.default.post(
                            name: .wellScrollToTop, object: nil)
                        hide()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, bottomInset)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: visible)
            .onPreferenceChange(WellScrollOffsetKey.self) { offset in
                onScrollOffset(offset)
                updateVisibility(offset: offset)
            }
            .onDisappear { hideTask?.cancel() }
    }

    private func updateVisibility(offset: CGFloat) {
        let delta = offset - lastOffset
        lastOffset = offset
        if offset < 120 {
            if visible { hide() }
            return
        }
        if delta > 0.5, !visible {
            show()
        } else if delta < -0.5, visible {
            hide()
        } else if visible {
            // 持续上滑时顺延 3.5 秒倒计时
            scheduleHide()
        }
    }

    private func show() {
        visible = true
        scheduleHide()
    }

    private func hide() {
        visible = false
        hideTask?.cancel()
        hideTask = nil
    }

    /// 3.5 秒不点击自动消失（用户指定）
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            visible = false
        }
    }
}

/// 页面内「回到顶部」动作广播：页面 ScrollView 收到后自行滚顶。
extension Notification.Name {
    static let wellScrollToTop = Notification.Name("well.scroll.toTop")
}

/// 页面装配：ScrollView 加 coordinateSpace + 偏移上报 + 收到广播用
/// ScrollViewReader 滚顶（SwiftUI 原生方式，不侵入 UIKit）。
/// 页面需在滚动内容最顶部放一个 `.id(topID)` 的锚点视图。
/// 用法：
/// ```
/// ScrollViewReader { proxy in
///     ScrollView { Color.clear.frame(height: 0).id("page-top") … }
///         .coordinateSpace(name: "playlistTop")
/// }
/// .modifier(WellScrollToTopPageModifier(space: "playlistTop", topID: "page-top",
///                                       proxy: proxy))
/// ```
struct WellScrollToTopPageModifier: ViewModifier {
    let space: String
    let topID: String
    let proxy: ScrollViewProxy
    @State private var box = ScrollOffsetBox()

    func body(content: Content) -> some View {
        content
            .modifier(WellScrollToTopModifier { box.value = $0 })
            .onReceive(NotificationCenter.default.publisher(for: .wellScrollToTop)) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(topID, anchor: .top)
                }
            }
    }
}

/// 偏移中转盒（不可观察引用，避免每帧写 @State）
final class ScrollOffsetBox {
    var value: CGFloat = 0
}
