import UIKit

/// A `UIImageView` that loads from a URL through the off-main `ImagePipeline`,
/// ignoring stale completions on reuse. Corners are rounded on the image view
/// itself (no sublayers) to avoid off-screen mask passes during scroll.
final class AsyncImageView: UIImageView {
    private var currentURL: URL?
    private var task: Task<Void, Never>?

    var placeholderColor: UIColor = DesignSystem.Color.surface

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        contentMode = .scaleAspectFill
        backgroundColor = placeholderColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setRounded(_ radius: CGFloat) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
    }

    func load(url: URL?, targetSize: CGSize) {
        task?.cancel()
        if let previous = currentURL, previous != url { ImageLoader.cancel(previous) }
        currentURL = url
        image = nil
        backgroundColor = placeholderColor
        guard let url else { return }
        let scale = max(traitCollection.displayScale, 1)
        let size = targetSize == .zero ? CGSize(width: 400, height: 400) : targetSize

        task = Task { [weak self] in
            let loaded = await ImageLoader.image(for: url, pointSize: size, scale: scale)
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.image = loaded
            self.backgroundColor = loaded == nil ? self.placeholderColor : .clear
        }
    }

    func cancel() {
        task?.cancel()
        if let url = currentURL { ImageLoader.cancel(url) }
        currentURL = nil
        image = nil
        backgroundColor = placeholderColor
    }
}
