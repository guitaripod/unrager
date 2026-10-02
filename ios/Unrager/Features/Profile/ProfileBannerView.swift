import UIKit
import UnragerKit

/// Where the profile's header image, and everything that reacts to it, is for a
/// given scroll position. A pure function of the offset, so scrolling back
/// replays the same motion in reverse: pulling down stretches the image from
/// the top, scrolling up lets the profile slide over it while it drifts at half
/// speed, softens and dims, and the avatar shrinks and fades before it reaches
/// the navigation bar, where the name takes its place.
struct ProfileBannerMotion: Equatable {
    static let parallax: CGFloat = 0.5
    static let avatarMinimumScale: CGFloat = 0.62
    static let dimmest: CGFloat = 0.38
    static let deepestZoom: CGFloat = 0.1

    var y: CGFloat
    var height: CGFloat
    var blur: CGFloat
    var dim: CGFloat
    var zoom: CGFloat
    var avatarScale: CGFloat
    var avatarAlpha: CGFloat

    /// `scroll` is how far the content has moved past its resting position
    /// (negative while pulled down), `safeTop` the space under the navigation
    /// bar, `visible` the height of the image below it at rest.
    static func at(scroll: CGFloat, safeTop: CGFloat, visible: CGFloat) -> ProfileBannerMotion {
        let rest = safeTop + visible
        guard scroll > 0 else {
            return ProfileBannerMotion(
                y: 0, height: rest - scroll, blur: 0, dim: 0, zoom: 0, avatarScale: 1, avatarAlpha: 1)
        }
        let progress = min(1, scroll / (visible + safeTop * 0.5))
        let eased = progress * progress
        return ProfileBannerMotion(
            y: -scroll * parallax, height: rest, blur: eased, dim: dimmest * progress,
            zoom: deepestZoom * progress,
            avatarScale: 1 - (1 - avatarMinimumScale) * min(1, scroll / visible),
            avatarAlpha: 1 - min(1, max(0, (scroll - visible * 0.65) / (visible * 0.65))))
    }

    /// How visible the navigation bar's own title is: none until the name in
    /// the header has scrolled under the bar, fully there a beat later.
    static func titleAlpha(scroll: CGFloat, nameBottom: CGFloat) -> CGFloat {
        min(1, max(0, (scroll - (nameBottom - 28)) / 28))
    }
}

/// The profile's header image, parked behind the feed so the profile scrolls
/// over it. A soft copy of the image fades in as the profile covers it, and an
/// account without a header image gets a wash of its own handle colour.
final class ProfileBannerView: UIView {
    private let wash = CAGradientLayer()
    private let picture = UIImageView()
    private let soft = UIImageView()
    private let dimmer = UIView()
    private var loadedURL: URL?
    private var task: Task<Void, Never>?

    /// Whether light status bar text reads on the top of the image. Updated
    /// when the image arrives; `onBrightnessChange` fires when it flips.
    private(set) var prefersLightContent = true
    var onBrightnessChange: (() -> Void)?
    private var motion = ProfileBannerMotion.at(scroll: 0, safeTop: 0, visible: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityIgnoresInvertColors = true
        layer.addSublayer(wash)
        for view in [picture, soft] {
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.alpha = 0
            addSubview(view)
        }
        dimmer.backgroundColor = .black
        dimmer.alpha = 0
        addSubview(dimmer)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProfileBannerView, _) in
            view.refreshWash()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var handle = ""

    /// Shows the account's header image, or its colour wash until the image
    /// arrives or when it has none.
    func configure(url: URL?, handle: String, imagesEnabled: Bool) {
        self.handle = handle
        refreshWash()
        guard imagesEnabled, let url else {
            task?.cancel()
            loadedURL = nil
            picture.image = nil
            soft.image = nil
            picture.alpha = 0
            soft.alpha = 0
            setLightContent(true)
            return
        }
        guard url != loadedURL else { return }
        task?.cancel()
        loadedURL = url
        let scale = max(traitCollection.displayScale, 1)
        task = Task { [weak self] in
            let size = CGSize(width: 780, height: 520)
            guard let image = await ImageLoader.image(for: url, pointSize: size, scale: scale) else { return }
            let (blurred, topBrightness) = await SoftImage.analyzed(image)
            guard !Task.isCancelled, let self, self.loadedURL == url else { return }
            self.picture.image = image
            self.soft.image = blurred
            self.setLightContent(topBrightness < 0.55)
            UIView.animate(withDuration: 0.25) { self.picture.alpha = 1 }
            self.apply(self.motion)
        }
    }

    /// Moves the image and everything layered on it to `motion`.
    func apply(_ motion: ProfileBannerMotion) {
        self.motion = motion
        frame = CGRect(x: 0, y: motion.y, width: superview?.bounds.width ?? bounds.width, height: motion.height)
        let zoom = 1 + motion.zoom
        for view in [picture, soft] {
            view.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        }
        soft.alpha = picture.image == nil ? 0 : motion.blur
        dimmer.alpha = motion.dim
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds
        CATransaction.commit()
        for view in [picture, soft] {
            let transform = view.transform
            view.transform = .identity
            view.frame = bounds
            view.transform = transform
        }
        dimmer.frame = bounds
    }

    private func setLightContent(_ light: Bool) {
        guard light != prefersLightContent else { return }
        prefersLightContent = light
        onBrightnessChange?()
    }

    private func refreshWash() {
        let base = DesignSystem.handleColor(handle).resolvedColor(with: traitCollection)
        wash.colors = [
            base.withAlphaComponent(0.85).cgColor,
            base.darkened(by: 0.45).cgColor,
        ]
        wash.startPoint = CGPoint(x: 0, y: 0)
        wash.endPoint = CGPoint(x: 1, y: 1)
    }
}

private extension UIColor {
    func darkened(by amount: CGFloat) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }
        return UIColor(hue: hue, saturation: saturation, brightness: brightness * (1 - amount), alpha: alpha)
    }
}
