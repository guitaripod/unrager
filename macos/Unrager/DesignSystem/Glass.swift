import AppKit

/// Liquid Glass chrome helpers. On macOS 26 the real `NSGlassEffectView` is
/// used (its `contentView` hosts content with native glass refraction);
/// earlier systems fall back to `NSVisualEffectView`. Glass lives only on the
/// navigation/chrome layer — never inside scrolling cells.
@MainActor
enum Glass {
    /// Wraps `content` in a glass surface, returning the view to add to the
    /// hierarchy. The content is hosted edge-to-edge.
    static func wrap(_ content: NSView,
                     material: NSVisualEffectView.Material = .sidebar,
                     cornerRadius: CGFloat = 0) -> NSView {
        if #available(macOS 26.0, *), let glass = glassEffectView(content: content, cornerRadius: cornerRadius) {
            return glass
        }
        return visualEffect(content: content, material: material, cornerRadius: cornerRadius)
    }

    /// A bare glass surface with no hosted content, for accent backgrounds.
    static func surface(material: NSVisualEffectView.Material = .hudWindow,
                        cornerRadius: CGFloat = 0) -> NSView {
        if #available(macOS 26.0, *), let glass = glassEffectView(content: nil, cornerRadius: cornerRadius) {
            return glass
        }
        return visualEffect(content: nil, material: material, cornerRadius: cornerRadius)
    }

    @available(macOS 26.0, *)
    private static func glassEffectView(content: NSView?, cornerRadius: CGFloat) -> NSView? {
        guard let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type else { return nil }
        let glass = glassClass.init(frame: .zero)
        glass.wantsLayer = true
        if cornerRadius > 0, glass.responds(to: NSSelectorFromString("setCornerRadius:")) {
            glass.setValue(cornerRadius, forKey: "cornerRadius")
        }
        if let content {
            content.translatesAutoresizingMaskIntoConstraints = false
            glass.setValue(content, forKey: "contentView")
        }
        return glass
    }

    private static func visualEffect(content: NSView?,
                                     material: NSVisualEffectView.Material,
                                     cornerRadius: CGFloat) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        if cornerRadius > 0 {
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.cornerCurve = .continuous
        }
        if let content {
            effect.addManaged(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                content.topAnchor.constraint(equalTo: effect.topAnchor),
                content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
        }
        return effect
    }
}
