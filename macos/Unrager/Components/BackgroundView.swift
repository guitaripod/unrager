import AppKit

/// A layer-backed `NSView` whose background is a dynamic `NSColor`, re-resolved
/// on appearance changes (a raw `layer.backgroundColor = color.cgColor` does
/// not update when light/dark flips). Used as the root view of feed-style
/// controllers and the content container.
final class BackgroundView: NSView {
    private let backgroundColor: NSColor
    var onAppearanceChange: (() -> Void)?

    init(color: NSColor) {
        backgroundColor = color
        super.init(frame: .zero)
        applyLayerBackground(backgroundColor)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        applyLayerBackground(backgroundColor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerBackground(backgroundColor)
        onAppearanceChange?()
    }
}
