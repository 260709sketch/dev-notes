import SwiftUI

/// 播放器界面过渡动效规格（★ 2026-10-16 从 MeloX NowPlayingMotionSpec 精简：
/// 原版 500+ 行且携带 NowPlayingTransitionContext 等依赖；这里只保留
/// NowPlayingInterfaceTransition 实际引用的面，数值取 Apple Music 观感默认）。
struct AMAnimationSpec: Equatable, Sendable {
    var animation: Animation?
    var hiddenOffset: CGFloat = 0
}

enum NowPlayingInterfaceLayer: Hashable, Sendable {
    case progress
    case transport
    case volume
    case pageSelector
}

struct AMInterfaceMotion {
    var utilityHiddenOffset: CGFloat = 24
    var utilityHiddenScale: CGFloat = 0.92
    var coreShow = AMAnimationSpec(animation: .spring(response: 0.42, dampingFraction: 0.85))
    var coreHide = AMAnimationSpec(animation: .spring(response: 0.32, dampingFraction: 0.9))
    var utilityShow = AMAnimationSpec(animation: .spring(response: 0.38, dampingFraction: 0.86))
    var utilityHide = AMAnimationSpec(animation: .spring(response: 0.3, dampingFraction: 0.92))

    func layerMotion(for layer: NowPlayingInterfaceLayer) -> AMAnimationSpec {
        switch layer {
        case .progress: return AMAnimationSpec(animation: .spring(response: 0.4, dampingFraction: 0.86), hiddenOffset: 28)
        case .transport: return AMAnimationSpec(animation: .spring(response: 0.42, dampingFraction: 0.85), hiddenOffset: 36)
        case .volume: return AMAnimationSpec(animation: .spring(response: 0.4, dampingFraction: 0.86), hiddenOffset: 32)
        case .pageSelector: return AMAnimationSpec(animation: .spring(response: 0.38, dampingFraction: 0.88), hiddenOffset: 30)
        }
    }

    func controlAnimation(for layer: NowPlayingInterfaceLayer, isVisible: Bool) -> AMAnimationSpec {
        isVisible ? layerMotion(for: layer) : layerMotion(for: layer)
    }
}

enum NowPlayingMotionSpec {
    static let appleMusic26 = NowPlayingMotionSpecHolder()
}

struct NowPlayingMotionSpecHolder {
    let interface = AMInterfaceMotion()
}
