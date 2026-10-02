import UIKit

/// The soft backdrop behind a picture that is shown whole inside a frame of
/// another shape: a frosted copy of the picture itself, stretched to fill the
/// frame, so the space around it reads as part of the picture instead of as
/// bars, and calmed with a veil of the page's own colour so the picture in
/// front stays the brightest thing. Hidden and empty until `show(from:key:)`
/// gives it a picture; showing the same picture again is free.
final class AmbientBackdropView: UIImageView {
    private var task: Task<Void, Never>?
    private var key: String?
    private let veil = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        isHidden = true
        isUserInteractionEnabled = false
        accessibilityIgnoresInvertColors = true
        veil.backgroundColor = DesignSystem.Color.background.withAlphaComponent(0.3)
        veil.isUserInteractionEnabled = false
        veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(veil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        veil.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Fills itself with the frosted copy of `image`, remembered under `key`
    /// so a recycled cell reuses it, and shows itself. Returns at once: the
    /// blur is made off the main thread and lands a moment later.
    func show(from image: UIImage, key: String) {
        isHidden = false
        if key == self.key, self.image != nil || task != nil { return }
        task?.cancel()
        self.key = key
        task = Task { [weak self] in
            let soft = await SoftImage.blurred(image, key: key)
            guard !Task.isCancelled else { return }
            self?.image = soft
            self?.task = nil
        }
    }

    /// Hides it and drops the picture, for a frame the picture fills.
    func clear() {
        task?.cancel()
        task = nil
        key = nil
        isHidden = true
        image = nil
    }
}
