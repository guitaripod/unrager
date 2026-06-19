import UIKit

/// iOS 26 Liquid Glass helpers. Deployment target is 26.0, so glass is the
/// baseline; these keep adoption consistent and in one place.
///
/// Rules followed throughout the app (from the WWDC 25 sessions):
/// glass lives on the *navigation layer* only — never inside collection-view
/// cells (off-screen render passes would wreck scroll performance). System
/// bars get glass automatically by leaving their backgrounds untouched.
extension UIVisualEffectView {
    static func glass(_ style: UIGlassEffect.Style = .regular,
                      tint: UIColor? = nil,
                      interactive: Bool = false) -> UIVisualEffectView {
        let view = UIVisualEffectView()
        let effect = UIGlassEffect(style: style)
        effect.isInteractive = interactive
        if let tint { effect.tintColor = tint }
        view.effect = effect
        return view
    }
}

extension UIView {
    /// Concentric corners so nested glass stays parallel to its container.
    func setConcentricCorners(minimum: CGFloat) {
        cornerConfiguration = .corners(radius: .containerConcentric(minimum: minimum))
    }

    func setCapsuleCorners() {
        cornerConfiguration = .capsule()
    }

    func setFixedCorners(_ radius: CGFloat) {
        cornerConfiguration = .corners(radius: .fixed(radius))
    }
}

extension UIButton.Configuration {
    /// Standard glass control.
    static func unragerGlass() -> UIButton.Configuration { .glass() }
    /// App-tinted prominent glass — reserved for the floating compose button.
    static func unragerProminentGlass() -> UIButton.Configuration { .prominentGlass() }
}
