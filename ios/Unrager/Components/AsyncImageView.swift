import UIKit

/// A `UIImageView` that loads from a URL through the off-main `ImagePipeline`,
/// ignoring stale completions on reuse. Corners are rounded on the image view
/// itself (no sublayers) to avoid off-screen mask passes during scroll.
final class AsyncImageView: UIImageView {
    private var currentURL: URL?
    private var task: Task<Void, Never>?

    var placeholderColor: UIColor = DesignSystem.Color.surface

    /// Whether a picture that arrives from the network dissolves in instead of
    /// popping. One that was already in memory always appears at once, so
    /// scrolling back never flickers.
    var fadesIn = false

    /// Called with the image each time one lands, from the cache or the network,
    /// just before it is shown, so it can set how the picture is fitted.
    var onLoad: ((UIImage) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        contentMode = .scaleAspectFill
        backgroundColor = placeholderColor
        accessibilityIgnoresInvertColors = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setRounded(_ radius: CGFloat) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
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
        backgroundColor = placeholderColor
        guard let url else { task = nil; return }
        let scale = max(traitCollection.displayScale, 1)
        let size = targetSize == .zero ? CGSize(width: 400, height: 400) : targetSize
        if let hit = ImageLoader.cachedImageImmediately(for: url, pointSize: size, scale: scale) {
            task = nil
            image = hit
            backgroundColor = .clear
            onLoad?(hit)
            return
        }

        task = Task { [weak self] in
            let loaded = await ImageLoader.image(for: url, pointSize: size, scale: scale)
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.task = nil
            if let loaded { self.onLoad?(loaded) }
            self.show(loaded)
        }
    }

    /// Puts `loaded` on screen, dissolving it in when `fadesIn` is on and the
    /// user hasn't asked for less motion.
    private func show(_ loaded: UIImage?) {
        let apply = {
            self.image = loaded
            self.backgroundColor = loaded == nil ? self.placeholderColor : .clear
        }
        guard fadesIn, loaded != nil, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.transition(with: self, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: apply)
    }

    func cancel() {
        task?.cancel()
        task = nil
        currentURL = nil
        image = nil
        backgroundColor = placeholderColor
    }
}
