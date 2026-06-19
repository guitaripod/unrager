import Photos
import UIKit
import UnragerKit

/// A modal that renders the focal tweet as a shareable postcard. It loads the
/// avatar and photo media up front, shows a live preview, lets the user switch
/// theme and toggle the display name / metrics, and then save to Photos, share,
/// or copy the rendered image. Present wrapped in a `UINavigationController`.
final class PostcardViewController: UIViewController {
    private let tweet: Tweet
    private var theme: PostcardTheme = PostcardStore.lastTheme
    private var options = PostcardView.Options(showsDisplayName: true, showsMetrics: false)

    private var avatar: UIImage?
    private var photos: [UIImage] = []

    private let scrollView = UIScrollView()
    private let previewContainer = UIView()
    private let cardShadow = UIView()
    private var cardWidthConstraint: NSLayoutConstraint?
    private var card: PostcardView?
    private let loadingIndicator = UIActivityIndicatorView(style: .large)

    private let swatchRow = UIStackView()
    private var swatches: [PostcardTheme: PostcardSwatch] = [:]
    private let nameSwitch = UISwitch()
    private let metricsSwitch = UISwitch()
    private let controls = UIStackView()

    private static let renderScale: CGFloat = 3

    init(tweet: Tweet) {
        self.tweet = tweet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Postcard"
        view.backgroundColor = DesignSystem.Color.background
        configureNavigation()
        configureLayout()
        loadImagesThenRender()
    }

    /// Fits the fixed-aspect 540pt card to the screen for preview (capped at the
    /// native render width on wide screens). The exported image is rendered from
    /// a separate instance at the full render width, so this never softens it.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let available = view.bounds.width - DesignSystem.Spacing.l * 2
        cardWidthConstraint?.constant = min(PostcardView.renderWidth, max(240, available))
    }

    // MARK: - Chrome

    private func configureNavigation() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: DesignSystem.icon("square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.share() })
    }

    private func configureLayout() {
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        view.addManaged(scrollView)

        cardShadow.layer.shadowColor = UIColor.black.cgColor
        cardShadow.layer.shadowOpacity = 0.18
        cardShadow.layer.shadowRadius = 18
        cardShadow.layer.shadowOffset = CGSize(width: 0, height: 8)
        previewContainer.addManaged(cardShadow)
        scrollView.addManaged(previewContainer)

        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.startAnimating()
        view.addManaged(loadingIndicator)

        let controlBar = makeControlBar()
        view.addManaged(controlBar)

        let cardWidth = cardShadow.widthAnchor.constraint(equalToConstant: PostcardView.renderWidth)
        cardWidthConstraint = cardWidth

        NSLayoutConstraint.activate([
            cardWidth,
            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: controlBar.topAnchor),

            previewContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            previewContainer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            cardShadow.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: DesignSystem.Spacing.l),
            cardShadow.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -DesignSystem.Spacing.l),
            cardShadow.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor),
        ])
    }

    private func makeControlBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = DesignSystem.Color.elevatedBackground

        swatchRow.axis = .horizontal
        swatchRow.spacing = DesignSystem.Spacing.m
        swatchRow.alignment = .center
        for theme in PostcardTheme.ordered {
            let swatch = PostcardSwatch(theme: theme, selected: theme == self.theme)
            swatch.onTap = { [weak self] in self?.select(theme) }
            swatches[theme] = swatch
            swatchRow.addArrangedSubview(swatch)
        }
        let swatchScroll = UIScrollView()
        swatchScroll.showsHorizontalScrollIndicator = false
        swatchScroll.addManaged(swatchRow)

        let nameToggle = makeToggle(title: "Display name", control: nameSwitch, isOn: options.showsDisplayName)
        nameSwitch.addAction(UIAction { [weak self] _ in self?.toggleName() }, for: .valueChanged)
        let metricsToggle = makeToggle(title: "Metrics", control: metricsSwitch, isOn: options.showsMetrics)
        metricsSwitch.addAction(UIAction { [weak self] _ in self?.toggleMetrics() }, for: .valueChanged)
        let toggleRow = UIStackView(arrangedSubviews: [nameToggle, metricsToggle])
        toggleRow.axis = .horizontal
        toggleRow.spacing = DesignSystem.Spacing.xl
        toggleRow.distribution = .fillEqually

        let actions = makeActionRow()

        controls.axis = .vertical
        controls.spacing = DesignSystem.Spacing.m
        controls.addArrangedSubview(swatchScroll)
        controls.addArrangedSubview(toggleRow)
        controls.addArrangedSubview(actions)
        bar.addManaged(controls)

        NSLayoutConstraint.activate([
            swatchScroll.heightAnchor.constraint(equalToConstant: PostcardSwatch.size + 4),
            swatchRow.topAnchor.constraint(equalTo: swatchScroll.contentLayoutGuide.topAnchor),
            swatchRow.bottomAnchor.constraint(equalTo: swatchScroll.contentLayoutGuide.bottomAnchor),
            swatchRow.leadingAnchor.constraint(equalTo: swatchScroll.contentLayoutGuide.leadingAnchor),
            swatchRow.trailingAnchor.constraint(equalTo: swatchScroll.contentLayoutGuide.trailingAnchor),
            swatchRow.heightAnchor.constraint(equalTo: swatchScroll.frameLayoutGuide.heightAnchor),

            controls.topAnchor.constraint(equalTo: bar.topAnchor, constant: DesignSystem.Spacing.l),
            controls.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: DesignSystem.Spacing.l),
            controls.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -DesignSystem.Spacing.l),
            controls.bottomAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.bottomAnchor, constant: -DesignSystem.Spacing.m),
        ])
        return bar
    }

    private func makeToggle(title: String, control: UISwitch, isOn: Bool) -> UIView {
        control.isOn = isOn
        control.onTintColor = DesignSystem.Color.accent
        let label = UILabel()
        label.text = title
        label.font = DesignSystem.Typography.handle()
        label.textColor = DesignSystem.Color.label
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = DesignSystem.Spacing.s
        return row
    }

    private func makeActionRow() -> UIView {
        let save = makeActionButton(title: "Save", symbol: "square.and.arrow.down", prominent: true) { [weak self] in
            self?.save()
        }
        let copy = makeActionButton(title: "Copy", symbol: "doc.on.doc", prominent: false) { [weak self] in
            self?.copyImage()
        }
        let shareButton = makeActionButton(title: "Share", symbol: "square.and.arrow.up", prominent: false) { [weak self] in
            self?.share()
        }
        let row = UIStackView(arrangedSubviews: [save, copy, shareButton])
        row.axis = .horizontal
        row.spacing = DesignSystem.Spacing.m
        row.distribution = .fillEqually
        return row
    }

    private func makeActionButton(title: String, symbol: String, prominent: Bool, action: @escaping () -> Void) -> UIButton {
        var config: UIButton.Configuration = prominent ? .filled() : .tinted()
        config.title = title
        config.image = DesignSystem.icon(symbol, pointSize: 16, weight: .semibold)
        config.imagePadding = DesignSystem.Spacing.s
        config.cornerStyle = .large
        config.baseBackgroundColor = DesignSystem.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    // MARK: - Image loading

    private func loadImagesThenRender() {
        Task { [weak self] in
            guard let self else { return }
            let scale = max(self.traitCollection.displayScale, 2)
            async let avatar = Self.loadAvatar(self.tweet, scale: scale)
            async let photos = Self.loadPhotos(self.tweet, scale: scale)
            self.avatar = await avatar
            self.photos = await photos
            self.loadingIndicator.stopAnimating()
            self.rebuildPreview()
        }
    }

    @MainActor
    private static func loadAvatar(_ tweet: Tweet, scale: CGFloat) async -> UIImage? {
        guard AppSettings.imagesEnabled, let url = tweet.author.avatarURL.flatMap(URL.init) else { return nil }
        return await ImageLoader.image(for: url, pointSize: CGSize(width: 120, height: 120), scale: scale)
    }

    /// Loads up to two photo (or video-poster) images, preferring the direct X
    /// CDN URL and falling back to the server media proxy — the same path the
    /// feed uses. Videos contribute their poster frame; polls/cards are skipped.
    @MainActor
    private static func loadPhotos(_ tweet: Tweet, scale: CGFloat) async -> [UIImage] {
        guard AppSettings.imagesEnabled else { return [] }
        let targets: [URL] = tweet.media.enumerated().compactMap { index, media in
            switch media.kind {
            case .photo, .video, .animatedGif:
                return URL(string: media.url) ?? AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: index)
            default:
                return nil
            }
        }
        var images: [UIImage] = []
        for url in targets.prefix(2) {
            if let image = await ImageLoader.image(for: url, pointSize: CGSize(width: 1080, height: 1080), scale: scale) {
                images.append(image)
            }
        }
        return images
    }

    // MARK: - Preview

    private func rebuildPreview() {
        card?.removeFromSuperview()
        let card = PostcardView(tweet: tweet, theme: theme, options: options, avatar: avatar, photos: photos)
        cardShadow.addManaged(card)
        card.pinEdges(to: cardShadow)
        card.layer.cornerRadius = DesignSystem.Radius.card
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        self.card = card
    }

    // MARK: - Actions

    private func select(_ theme: PostcardTheme) {
        guard theme != self.theme else { return }
        Haptics.selection()
        swatches[self.theme]?.setSelected(false)
        self.theme = theme
        PostcardStore.lastTheme = theme
        swatches[theme]?.setSelected(true)
        rebuildPreview()
    }

    private func toggleName() {
        options.showsDisplayName = nameSwitch.isOn
        rebuildPreview()
    }

    private func toggleMetrics() {
        options.showsMetrics = metricsSwitch.isOn
        rebuildPreview()
    }

    private func renderedImage() -> UIImage {
        let card = PostcardView(tweet: tweet, theme: theme, options: options, avatar: avatar, photos: photos)
        return card.render(scale: Self.renderScale)
    }

    private func save() {
        let image = renderedImage()
        Task {
            do {
                try await Self.saveToPhotos(image)
                Haptics.success()
                toast("Saved to Photos")
            } catch {
                AppLogger.shared.warn("save postcard failed: \(error)", category: .media)
                present(AlertFactory.error(error, title: "Couldn't save"), animated: true)
            }
        }
    }

    private func copyImage() {
        UIPasteboard.general.image = renderedImage()
        Haptics.success()
        toast("Copied")
    }

    private func share() {
        let activity = UIActivityViewController(activityItems: [renderedImage()], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(activity, animated: true)
    }

    @MainActor
    private static func saveToPhotos(_ image: UIImage) async throws {
        try await ensureAuthorized()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    private static func ensureAuthorized() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else { throw MediaSaver.Failure.permissionDenied }
        default:
            throw MediaSaver.Failure.permissionDenied
        }
    }

    private func toast(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { alert.dismiss(animated: true) }
    }
}

/// A tappable circular theme swatch showing the theme's background and accent.
private final class PostcardSwatch: UIControl {
    static let size: CGFloat = 44

    var onTap: (() -> Void)?
    private let theme: PostcardTheme
    private let ring = CALayer()
    private let gradient = CAGradientLayer()
    private let accentDot = UIView()

    init(theme: PostcardTheme, selected: Bool) {
        self.theme = theme
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.size).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size).isActive = true
        accessibilityLabel = theme.title
        accessibilityTraits = .button

        gradient.colors = [theme.background.cgColor, (theme.backgroundEnd ?? theme.background).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.cornerRadius = Self.size / 2
        layer.addSublayer(gradient)

        ring.borderWidth = 3
        ring.cornerRadius = Self.size / 2
        layer.addSublayer(ring)

        accentDot.translatesAutoresizingMaskIntoConstraints = false
        accentDot.backgroundColor = theme.accent
        accentDot.layer.cornerRadius = 6
        accentDot.isUserInteractionEnabled = false
        addSubview(accentDot)
        NSLayoutConstraint.activate([
            accentDot.widthAnchor.constraint(equalToConstant: 12),
            accentDot.heightAnchor.constraint(equalToConstant: 12),
            accentDot.centerXAnchor.constraint(equalTo: centerXAnchor),
            accentDot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        setSelected(selected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        ring.frame = bounds
    }

    func setSelected(_ selected: Bool) {
        ring.borderColor = selected
            ? DesignSystem.Color.accent.cgColor
            : DesignSystem.Color.separator.cgColor
        accentDot.isHidden = !selected
    }

    @objc private func tapped() { onTap?() }
}

/// Persists the last-picked postcard theme so it survives across presentations.
enum PostcardStore {
    private static let key = "unrager.postcardTheme"
    static var lastTheme: PostcardTheme {
        get { PostcardTheme(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .glass }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
