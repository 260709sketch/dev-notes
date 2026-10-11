#if os(iOS)
import UIKit
import Combine

/// 全局滑动检测器：检测应用内是否有 ScrollView 正在滑动
/// 滑动时通知液态玻璃视图降低渲染质量，停止后恢复
public final class WellScrollDetector: ObservableObject {
    public static let shared = WellScrollDetector()

    @Published public private(set) var isScrolling = false

    private var scrollingScrollViews = Set<UIScrollView>()
    private var stopTimer: Timer?

    private init() {
        // 监听 ScrollView 滑动相关通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSNotification.Name("UIScrollViewDidScrollNotification"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndDragging(_:)),
            name: NSNotification.Name("UIScrollViewDidEndDraggingNotification"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndDecelerating(_:)),
            name: NSNotification.Name("UIScrollViewDidEndDeceleratingNotification"),
            object: nil
        )
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard let scrollView = notification.object as? UIScrollView else { return }
        // 忽略很小的内容（如分段控制器内部的滑动）
        guard scrollView.frame.height > 100 else { return }
        // 关键：只把「用户正在拖动」视为滚动。
        // 切换 tab / 页面布局重排时 UIScrollView 也会发 didScroll 通知，若不加过滤，
        // 液态玻璃底栏会误判为滚动 → 触发降分辨率/改帧率重建 → 表现为“切换页面抖一下”。
        guard scrollView.isDragging || scrollView.isDecelerating else { return }

        scrollingScrollViews.insert(scrollView)
        updateScrollingState()

        // 每次滑动都重置停止计时器
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.scrollingScrollViews.removeAll()
            self?.updateScrollingState()
        }
    }

    @objc private func scrollViewDidEndDragging(_ notification: Notification) {
        guard let scrollView = notification.object as? UIScrollView else { return }
        // 如果没有减速，直接移除
        if !scrollView.isDecelerating {
            scrollingScrollViews.remove(scrollView)
            updateScrollingState()
        }
    }

    @objc private func scrollViewDidEndDecelerating(_ notification: Notification) {
        guard let scrollView = notification.object as? UIScrollView else { return }
        scrollingScrollViews.remove(scrollView)
        updateScrollingState()
    }

    private func updateScrollingState() {
        let scrolling = !scrollingScrollViews.isEmpty
        if scrolling != isScrolling {
            isScrolling = scrolling
        }
    }
}
#endif
