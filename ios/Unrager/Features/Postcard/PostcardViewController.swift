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
    private var quotedPhotos: [UIImage] = []
    private var exporting = false
    private var imagesLoaded = false
    private var threadEntries: [PostcardView.Entry]?
    private var threadLoading = false

    private let scrollView = UIScrollView()
    private let previewContainer = UIView()
    private let cardShadow = UIView()
    private let cardClip = UIView()
    private var cardWidthConstraint: NSLayoutConstraint?
    private var cardHeightConstraint: NSLayoutConstraint?
    private var card: PostcardView?
    private var cardNaturalSize: CGSize = .zero
    private var actionButtons: [UIButton] = []
    private let loadingIndicator = UIActivityIndicatorView(style: .large)

    private let swatchRow = UIStackView()
    private var swatches: [PostcardTheme: PostcardSwatch] = [:]
    private let nameSwitch = UISwitch()
    private let metricsSwitch = UISwitch()
    private let threadSwitch = UISwitch()
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
        PostcardTheme.appearance = traitCollection.userInterfaceStyle
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: PostcardViewController, _) in
            PostcardTheme.appearance = controller.traitCollection.userInterfaceStyle
            if controller.imagesLoaded { controller.rebuildPreview() }
        }
        configureNavigation()
        configureLayout()
        updateExportEnabled()
        loadImagesThenRender()
    }

    /// The preview is the export itself: a card laid out at the full 540 pt
    /// width, shown shrunk to fit the screen. Laying it out at the screen's
    /// width instead would wrap the text differently from the image that gets
    /// saved or shared.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPreview()
    }

    private func layoutPreview() {
        let available = view.bounds.width - DesignSystem.Spacing.l * 2
        let displayWidth = min(PostcardView.renderWidth, max(240, available))
        cardWidthConstraint?.constant = displayWidth
        guard let card, cardNaturalSize.width > 0 else { return }
        let scale = displayWidth / cardNaturalSize.width
        card.transform = .identity
        card.bounds = CGRect(origin: .zero, size: cardNaturalSize)
        card.layer.anchorPoint = .zero
        card.layer.position = .zero
        card.transform = CGAffineTransform(scaleX: scale, y: scale)
        cardHeightConstraint?.constant = cardNaturalSize.height * scale
    }

    /// Export is offered only once everything it draws is in: the photos and
    /// avatar, and — with Thread on — the thread. Earlier it would save a card
    /// with its pictures missing.
    private func updateExportEnabled() {
        let ready = imagesLoaded && !threadLoading && !exporting
        actionButtons.forEach { $0.isEnabled = ready }
        navigationItem.rightBarButtonItem?.isEnabled = ready
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
        cardClip.clipsToBounds = true
        cardClip.layer.cornerRadius = DesignSystem.Radius.card
        cardClip.layer.cornerCurve = .continuous
        cardShadow.addManaged(cardClip)
        cardClip.pinEdges(to: cardShadow)
        previewContainer.addManaged(cardShadow)
        scrollView.addManaged(previewContainer)

        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.startAnimating()
        view.addManaged(loadingIndicator)

        let controlBar = makeControlBar()
        view.addManaged(controlBar)

        let cardWidth = cardShadow.widthAnchor.constraint(equalToConstant: PostcardView.renderWidth)
        cardWidthConstraint = cardWidth
        let cardHeight = cardShadow.heightAnchor.constraint(equalToConstant: PostcardView.renderWidth)
        cardHeightConstraint = cardHeight

        NSLayoutConstraint.activate([
            cardWidth,
            cardHeight,
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
        let threadToggle = makeToggle(title: "Thread", control: threadSwitch, isOn: options.showsThread)
        threadSwitch.addAction(UIAction { [weak self] _ in self?.toggleThread() }, for: .valueChanged)
        let toggleRow = UIStackView(arrangedSubviews: [nameToggle, metricsToggle, threadToggle])
        toggleRow.axis = .vertical
        toggleRow.spacing = DesignSystem.Spacing.s
        toggleRow.alignment = .fill

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

    /// A full-width settings-style row: label on the left, switch pinned right,
    /// so labels never truncate and the switch never overlaps them.
    private func makeToggle(title: String, control: UISwitch, isOn: Bool) -> UIView {
        control.isOn = isOn
        control.accessibilityLabel = title
        control.onTintColor = DesignSystem.Color.accent
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let label = UILabel()
        label.text = title
        label.font = DesignSystem.Typography.handle()
        label.textColor = DesignSystem.Color.label
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, spacer, control])
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
        actionButtons = [save, copy, shareButton]
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
            async let quotedPhotos = Self.loadQuotedPhotos(self.tweet, scale: scale)
            self.avatar = await avatar
            self.photos = await photos
            self.quotedPhotos = await quotedPhotos
            await PostcardView.prefetchEmoji(entries: self.activeEntries)
            self.loadingIndicator.stopAnimating()
            self.imagesLoaded = true
            self.rebuildPreview()
            self.updateExportEnabled()
        }
    }

    @MainActor
    private static func loadAvatar(_ tweet: Tweet, scale: CGFloat) async -> UIImage? {
        guard AppSettings.imagesEnabled, let url = tweet.author.avatarURL.flatMap(URL.init) else { return nil }
        return await ImageLoader.image(for: url, pointSize: CGSize(width: 120, height: 120), scale: scale)
    }

    /// The widest a photo is ever drawn is the card's own width, so decoding
    /// beyond that only spends memory.
    private static let photoPoints = CGSize(width: PostcardView.renderWidth, height: PostcardView.renderWidth)

    /// Loads up to `limit` photo (or video-poster) images, all at once and in
    /// their original order, preferring the direct X CDN URL and falling back to
    /// the server media proxy — the same path the feed uses. Videos contribute
    /// their poster frame; polls/cards are skipped.
    @MainActor
    private static func loadPhotos(_ tweet: Tweet, scale: CGFloat, limit: Int = 4) async -> [UIImage] {
        guard AppSettings.imagesEnabled else { return [] }
        let targets: [URL] = tweet.media.enumerated().compactMap { index, media in
            switch media.kind {
            case .photo, .video, .animatedGif:
                return URL(string: media.url) ?? AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: index)
            default:
                return nil
            }
        }
        return await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (position, url) in targets.prefix(limit).enumerated() {
                group.addTask { (position, await ImageLoader.image(for: url, pointSize: Self.photoPoints, scale: scale)) }
            }
            var loaded: [(Int, UIImage)] = []
            for await (position, image) in group {
                if let image { loaded.append((position, image)) }
            }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    @MainActor
    private static func loadQuotedPhotos(_ tweet: Tweet, scale: CGFloat) async -> [UIImage] {
        guard let quoted = tweet.quotedTweet else { return [] }
        return await loadPhotos(quoted, scale: scale, limit: 2)
    }

    // MARK: - Preview

    /// The blocks the postcard renders: the full root→focal chain when Thread is
    /// on and fetched, else just the focal tweet (default, unchanged behavior).
    private var activeEntries: [PostcardView.Entry] {
        let single = PostcardView.Entry(tweet: tweet, avatar: avatar, photos: photos, quotedPhotos: quotedPhotos)
        return (options.showsThread ? threadEntries : nil) ?? [single]
    }

    private func rebuildPreview() {
        card?.removeFromSuperview()
        let card = PostcardView(entries: activeEntries, theme: theme, options: options)
        cardNaturalSize = card.fittingSize()
        card.frame = CGRect(origin: .zero, size: cardNaturalSize)
        cardClip.addSubview(card)
        card.layoutIfNeeded()
        self.card = card
        layoutPreview()
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

    /// Turning Thread on stacks the root→focal chain. The chain is fetched once
    /// and cached, so re-toggling (or changing theme/name/metrics) never refetches.
    private func toggleThread() {
        options.showsThread = threadSwitch.isOn
        if options.showsThread, threadEntries == nil, !threadLoading {
            fetchThread()
        } else {
            rebuildPreview()
            updateExportEnabled()
        }
    }

    #if DEBUG
    /// Screenshot-QA hook: flip the Thread toggle on as if tapped.
    func debugEnableThread() {
        threadSwitch.isOn = true
        toggleThread()
    }

    /// Screenshot-QA hook: render the export and write it to Documents so the
    /// rasterized result (not the live preview) can be inspected.
    func debugSaveExport() {
        Task { [weak self] in
            guard let self else { return }
            let image = await self.renderedImage()
            guard let data = image.pngData(),
                  let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            try? data.write(to: dir.appendingPathComponent("postcard-export.png"))
            AppLogger.shared.info("postcard export \(Int(image.size.width))x\(Int(image.size.height)) saved", category: .app)
        }
    }
    #endif

    private func fetchThread() {
        threadLoading = true
        loadingIndicator.startAnimating()
        updateExportEnabled()
        Task { [weak self] in
            guard let self else { return }
            let entries = await Self.loadThreadEntries(focal: self.tweet)
            self.threadLoading = false
            self.loadingIndicator.stopAnimating()
            guard self.options.showsThread else { self.updateExportEnabled(); return }
            guard let entries else {
                self.threadSwitch.setOn(false, animated: true)
                self.options.showsThread = false
                self.updateExportEnabled()
                self.present(AlertFactory.error(ThreadUnavailable(), title: "Couldn't load the thread"), animated: true)
                return
            }
            self.threadEntries = entries
            self.rebuildPreview()
            self.updateExportEnabled()
        }
    }

    private struct ThreadUnavailable: LocalizedError {
        var errorDescription: String? { "The conversation couldn't be fetched, so the postcard shows this post alone." }
    }

    /// Fetches the thread and walks the parent chain from the focal tweet up to
    /// the root (cap 20, mirroring the TUI), then loads each tweet's avatar and
    /// first photo, all of them at once. Nil when the thread can't be fetched,
    /// so a failure is never kept as if it were the thread.
    @MainActor
    private static func loadThreadEntries(focal: Tweet) async -> [PostcardView.Entry]? {
        guard let thread = try? await AppEnvironment.shared.api.thread(id: focal.restID) else { return nil }
        let chain = ancestorChain(focal: thread.focal ?? focal, ancestors: thread.ancestors)
        let entries = await withTaskGroup(of: (Int, PostcardView.Entry).self) { group in
            for (position, tweet) in chain.enumerated() {
                group.addTask {
                    let avatar = await loadAvatar(tweet, scale: Self.renderScale)
                    let photos = await loadPhotos(tweet, scale: Self.renderScale, limit: 1)
                    let quotedPhotos = await loadQuotedPhotos(tweet, scale: Self.renderScale)
                    return (position, PostcardView.Entry(
                        tweet: tweet, avatar: avatar, photos: photos, quotedPhotos: quotedPhotos))
                }
            }
            var loaded: [(Int, PostcardView.Entry)] = []
            for await item in group { loaded.append(item) }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
        await PostcardView.prefetchEmoji(entries: entries)
        return entries
    }

    /// Climbs `in_reply_to_tweet_id` from the focal tweet to the root, returning
    /// root-first / focal-last. Guards against cycles and caps depth.
    private static func ancestorChain(focal: Tweet, ancestors: [Tweet]) -> [Tweet] {
        var byID = Dictionary(ancestors.map { ($0.restID, $0) }, uniquingKeysWith: { a, _ in a })
        byID[focal.restID] = focal
        var chain = [focal]
        var visited: Set<String> = [focal.restID]
        var current = focal.inReplyToTweetID
        while let id = current, chain.count < 20, visited.insert(id).inserted, let parent = byID[id] {
            chain.append(parent)
            current = parent.inReplyToTweetID
        }
        return chain.reversed()
    }

    /// Renders the export from a fresh full-width card. Awaits the Twemoji
    /// prefetch first so the rasterized labels substitute every emoji as a
    /// cache hit; the rasterization itself is synchronous and window-free.
    private func renderedImage() async -> UIImage {
        let entries = activeEntries
        await PostcardView.prefetchEmoji(entries: entries)
        let card = PostcardView(entries: entries, theme: theme, options: options)
        return card.render(scale: Self.renderScale)
    }

    /// Serializes the export actions: renders once per tap, ignoring re-taps
    /// while a render (emoji prefetch included) is still in flight.
    private func withRenderedImage(_ handle: @escaping @MainActor (UIImage) -> Void) {
        guard !exporting, imagesLoaded, !threadLoading else { return }
        exporting = true
        updateExportEnabled()
        Task { [weak self] in
            guard let self else { return }
            let image = await self.renderedImage()
            self.exporting = false
            self.updateExportEnabled()
            handle(image)
        }
    }

    private func save() {
        withRenderedImage { [weak self] image in
            guard let self else { return }
            Task {
                do {
                    try await MediaSaver.save(image: image)
                    Haptics.success()
                    self.showToast("Saved to Photos")
                } catch {
                    AppLogger.shared.warn("save postcard failed: \(error)", category: .media)
                    self.present(MediaSaver.alert(for: error), animated: true)
                }
            }
        }
    }

    private func copyImage() {
        withRenderedImage { [weak self] image in
            UIPasteboard.general.image = image
            Haptics.success()
            self?.showToast("Copied")
        }
    }

    private func share() {
        withRenderedImage { [weak self] image in
            guard let self else { return }
            let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            activity.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItem
            self.present(activity, animated: true)
        }
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
        isAccessibilityElement = true
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
        accessibilityTraits = selected ? [.button, .selected] : .button
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
