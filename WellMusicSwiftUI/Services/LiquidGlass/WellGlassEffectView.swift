//
//  WellGlassEffectView.swift
//  WellMusicSwiftUI
//
//  UIVisualEffect subclasses and view factory for the WellMusic liquid glass.
//  Adapted from the open-source LiquidGlass library (https://github.com/alexeyden/LiquidGlass, MIT).
//

#if os(iOS)
import UIKit

public class WellGlassEffectView: UIView, AnyVisualEffectView {

    public let contentView = UIView()
    public var effect: UIVisualEffect?

    var wellGlassView: WellGlassView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let wellGlassView {
                insertSubview(wellGlassView, belowSubview: contentView)
                wellGlassView.isPaused = _isPaused
            }
        }
    }

    /// 暂停液态玻璃渲染循环（静态背景模式下使用，节省性能）
    private var _isPaused = false
    var isPaused: Bool {
        get { _isPaused }
        set {
            _isPaused = newValue
            wellGlassView?.isPaused = newValue
        }
    }

    public required init(effect: WellGlassEffect, preferredFramesPerSecond: Int = 60) {
        self.effect = effect

        super.init(frame: .zero)

        let glassConfig = effect.customWellGlass ?? effect.style.wellGlass
        let wellGlassView = WellGlassView(glassConfig, preferredFramesPerSecond: preferredFramesPerSecond)
        addSubview(wellGlassView)
        self.wellGlassView = wellGlassView

        setupContentView()
    }

    public required init(effect: WellGlassContainerEffect) {
        self.effect = effect

        super.init(frame: .zero)

        setupContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupContentView() {
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        wellGlassView?.frame = contentView.frame
        wellGlassView?.layer.cornerRadius = layer.cornerRadius
        wellGlassView?.layer.cornerCurve = layer.cornerCurve
    }
}

/// A visual effect that renders a glass material.
public class WellGlassEffect: UIVisualEffect {

    public enum Style {
        case regular, clear, lens, thumb, white

        @available(iOS 26.0, *)
        var nativeStyle: UIGlassEffect.Style {
            switch self {
            case .regular: .regular
            case .clear: .clear
            case .lens: .regular
            case .thumb: .clear
            case .white: .regular
            }
        }

        var wellGlass: WellGlass {
            switch self {
            case .regular: .regular
            case .clear: .regular // TODO: Add clear WellGlass preset.
            case .lens: .lens
            case .thumb: .thumb()
            case .white: .white
            }
        }
    }
    let style: Style

    let isNative: Bool

    /// 自定义 WellGlass 配置，设置后优先使用
    var customWellGlass: WellGlass?

    /// Enables interactive behavior for the glass effect.
    public var isInteractive = false

    /// A tint color applied to the glass.
    public var tintColor: UIColor?

    /// Creates a glass effect with the specified style.
    /// - Parameters:
    ///   - style: The glass effect style.
    ///   - isNative: Whether to use `UIGlassEffect` on iOS 26+.
    public init(style: Style, isNative: Bool = true) {
        self.style = style
        self.isNative = isNative
        super.init()
    }

    /// Creates a glass effect with custom WellGlass configuration.
    convenience init(customWellGlass: WellGlass) {
        self.init(style: .regular, isNative: false)
        self.customWellGlass = customWellGlass
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A `WellGlassContainerEffect` renders multiple glass elements into a combined effect.
///
/// When using `WellGlassContainerEffect` with a `WellVisualEffectView` you can
/// add individual glass elements to the visual effect view's contentView by nesting `WellVisualEffectView`'s
/// configured with `WellGlassEffect`. In that configuration, the glass container will render all glass elements
/// in one combined view, behind the visual effect view's `contentView`.
public class WellGlassContainerEffect: UIVisualEffect {

    let isNative: Bool

    /// The spacing specifies the distance between elements at which they begin to merge.
    public var spacing = 10.0

    /// Creates a combined glass effect.
    /// - Parameters:
    ///   - isNative: Whether to use `UIGlassContainerEffect` on iOS 26+.
    public init(isNative: Bool = true) {
        self.isNative = isNative
        super.init()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

public protocol AnyVisualEffectView: UIView {
    var contentView: UIView { get }
    var effect: UIVisualEffect? { get set }
}

extension UIVisualEffectView: AnyVisualEffectView { }

public func WellVisualEffectView(effect: UIVisualEffect?) -> AnyVisualEffectView {
    if let effect = effect as? WellGlassEffect {
        if #available(iOS 26.0, *), effect.isNative {
            let nativeEffect = UIGlassEffect(style: effect.style.nativeStyle)
            nativeEffect.isInteractive = effect.isInteractive
            nativeEffect.tintColor = effect.tintColor
            // Returns the native iOS 26 Liquid Glass view
            return UIVisualEffectView(effect: nativeEffect)
        } else {
            // Returns custom (iOS 26 以下) implementation
            return WellGlassEffectView(effect: effect)
        }
    } else if let effect = effect as? WellGlassContainerEffect {
        if #available(iOS 26.0, *), effect.isNative {
            let nativeEffect = UIGlassContainerEffect()
            nativeEffect.spacing = effect.spacing
            // Returns the native iOS 26 Liquid Glass Container view
            return UIVisualEffectView(effect: nativeEffect)
        } else {
            // Returns custom (iOS 26 以下) implementation
            return WellGlassEffectView(effect: effect)
        }
    } else {
        return UIVisualEffectView(effect: effect)
    }
}
#endif