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

/// ⚠️ 2026-10-16 第十一轮二修：上一版把探针做成「内容里的 0 高行」——
/// LazyVStack 滚远后会**卸载**该行 → 偏好值消失归零 → 浮钮刚出现就被隐藏
/// （用户：「回顶按钮我没看到」）。正确做法 = `background(GeometryReader)`
/// 打在**整个内容根容器**上（根容器始终在、随滚动移动）。
struct WellScrollOffsetReporter: ViewModifier {
    let space: String

    func body(content: Content) -> some View {
        content.background(
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
/// * 向下滚过 80pt 以上 → 浮现；往回滑 → 消失；接近顶部 → 消失；
/// * 浮现后 3.5 秒不点击自动消失（用户指定）。
struct WellScrollToTopModifier: ViewModifier {
    /// ★ 2026-10-16 三修：dock（迷你播放器 52 + 间距 8 + 胶囊 64 + 距底 42 ≈ 166pt）
    ///   **会盖住页面 overlay** —— 上一版 152pt 的浮钮正好藏在 dock 后面（用户
    ///   「回顶按钮在哪」）。抬到 108+80=188，确保整颗浮钮露在 dock 上方。
    var bottomInset: CGFloat = 190
    let onScrollOffset: (CGFloat) -> Void

    @State private var visible = false
    /// ⚠️⚠️ 性能铁律（2026-10-16 第十一轮实亏一版）：上一版把每帧变化的
    /// `lastOffset` 与 `hideTask` 直接写进 @State —— 滚动时整页每帧重算 →
    /// LazyVStack 布局抖动，专辑/歌单页表现成「下滑和上滑来回撞上面的墙」。
    /// 高频值一律进**不可观察引用盒**。
    @State private var deltaBox = ScrollDeltaBox()

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
                    // 动画只作用在浮钮自身，不挂在整页容器上
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .animation(.easeInOut(duration: 0.2), value: visible)
                }
            }
            .onPreferenceChange(WellScrollOffsetKey.self) { offset in
                onScrollOffset(offset)
                updateVisibility(offset: offset)
            }
            .onDisappear { deltaBox.hideTask?.cancel() }
    }

    private func updateVisibility(offset: CGFloat) {
        // ★★ 2026-10-16 四修（用户两次追问「回顶按钮在哪」）：改成**持久显示** ——
        //   只要页面滚动超过 200pt，浮钮常驻；回到顶部附近才收起。
        //   不再依赖滑动方向 / 3.5 秒计时（用户停止滚动后按钮就消失，
        //   正是「找不到」的元凶）。
        if offset > 200 {
            if !visible { show() }
        } else {
            if visible { hide() }
        }
    }

    private func show() {
        visible = true
    }

    private func hide() {
        visible = false
        deltaBox.hideTask?.cancel()
        deltaBox.hideTask = nil
    }

    /// 3.5 秒不点击自动消失（用户指定）。⚠️ hideTask 存引用盒 —— 滚动时每帧
    /// 重排计时也不能写 @State。
    private func scheduleHide() {
        deltaBox.hideTask?.cancel()
        deltaBox.hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            visible = false
        }
    }
}

/// 滚动浮钮的高频状态盒（不参与 SwiftUI 观察，避免每帧视图失效）
final class ScrollDeltaBox {
    var lastOffset: CGFloat = 0
    var hideTask: Task<Void, Never>?
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
