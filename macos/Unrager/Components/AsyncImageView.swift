import AppKit

/// An `NSImageView` that loads an image off-main through `ImageLoader`, with
/// a stale-completion guard for cell reuse and rounded-corner support. Mirrors
/// the iOS `AsyncImageView`.
final class AsyncImageView: NSImageView {
    var placeholderColor: NSColor = DesignSystem.Color.surface {
        didSet { applyPlaceholderBackground() }
    }

    private var currentURL: URL?
    private var task: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        imageScaling = .scaleProportionallyUpOrDown
        layer?.masksToBounds = true
        applyPlaceholderBackground()
    }

    func setRounded(_ radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    /// Renders to fill the view, cropping overflow (avatar/media style).
    func setFill() {
        imageScaling = .scaleProportionallyUpOrDown
        layer?.contentsGravity = .resizeAspectFill
    }

    /// Renders scaled to fit (letterboxed, never cropped) — matches an inline
    /// video poster behind an aspect-fit `AVPlayerLayer`.
    func setFit() {
        imageScaling = .scaleProportionallyUpOrDown
        layer?.contentsGravity = .resizeAspect
    }

    /// Loads `url` through the pipeline. Cancelling `task` is the single
    /// cancellation signal — the pipeline withdraws this view's interest via
    /// structured cancellation. A reconfigure with the same URL while a load is
    /// in flight (or after the image landed) is a no-op, so repeated
    /// reconfigures can't stack up extra interest registrations.
    func load(url: URL?, targetSize: CGSize) {
        if let url, url == currentURL, image != nil || task != nil { return }
        task?.cancel()
        currentURL = url
        image = nil
        applyPlaceholderBackground()
        guard let url else { task = nil; return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = targetSize == .zero ? CGSize(width: 400, height: 400) : targetSize
        task = Task { [weak self] in
            let loaded = await ImageLoader.image(for: url, pointSize: size, scale: scale)
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.task = nil
            self.image = loaded
            self.layer?.backgroundColor = loaded == nil ? self.placeholderColor.cgColor : NSColor.clear.cgColor
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        currentURL = nil
        image = nil
        applyPlaceholderBackground()
    }

    private func applyPlaceholderBackground() {
        wantsLayer = true
        layer?.backgroundColor = image == nil ? placeholderColor.cgColor : NSColor.clear.cgColor
    }

    override func updateLayer() {
        super.updateLayer()
        applyPlaceholderBackground()
    }

    override var allowsVibrancy: Bool { false }
}
