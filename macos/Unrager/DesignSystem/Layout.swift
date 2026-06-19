import AppKit

extension NSView {
    /// Adds `subview` with auto-layout enabled in one call.
    func addManaged(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
    }

    /// Sets a layer background from a dynamic `NSColor`, resolved inside the
    /// view's effective appearance so it stays correct in light/dark. Re-call
    /// from `viewDidChangeEffectiveAppearance` since `cgColor` doesn't update.
    func applyLayerBackground(_ color: NSColor) {
        wantsLayer = true
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        layer?.backgroundColor = resolved
    }

    /// Pins all four edges of the receiver to `other`, with optional insets.
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}
