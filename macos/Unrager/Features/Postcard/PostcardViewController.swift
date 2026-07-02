import AppKit
import UnragerKit

/// A sheet that renders the focal tweet as a shareable postcard. It loads the
/// avatar and photo media up front, shows a live preview, lets the user switch
/// theme and toggle the display name / metrics / thread, and then save to disk,
/// copy, or share the rendered image. Mirrors the iOS `PostcardViewController`,
/// presented via `presentAsSheet`.
@MainActor
final class PostcardViewController: NSViewController {
    private let tweet: Tweet
    private var theme: PostcardTheme = PostcardStore.lastTheme
    private var options = PostcardView.Options(showsDisplayName: true, showsMetrics: false, showsThread: false)

    private var avatar: NSImage?
    private var photos: [NSImage] = []
    private var threadEntries: [PostcardView.Entry]?
    private var threadLoading = false

    private let scrollView = NSScrollView()
    private let previewImageView = NSImageView()
    private let spinner = NSProgressIndicator()

    private let swatchRow = NSStackView()
    private var swatches: [PostcardTheme: PostcardSwatch] = [:]
    private let nameToggle = NSButton(checkboxWithTitle: "Display name", target: nil, action: nil)
    private let metricsToggle = NSButton(checkboxWithTitle: "Metrics", target: nil, action: nil)
    private let threadToggle = NSButton(checkboxWithTitle: "Thread", target: nil, action: nil)

    private static let renderScale: CGFloat = 3

    init(tweet: Tweet) {
        self.tweet = tweet
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 720))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Postcard"
        configureLayout()
        loadImagesThenRender()
    }

    // MARK: - Layout

    private func configureLayout() {
        let titleLabel = NSTextField(labelWithString: "Postcard")
        titleLabel.font = DesignSystem.Typography.title()
        titleLabel.textColor = DesignSystem.Color.label

        let closeButton = NSButton(title: "Done", target: self, action: #selector(close))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        let header = NSStackView(views: [titleLabel, NSView(), closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.imageAlignment = .alignTop
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = DesignSystem.Radius.card
        previewImageView.layer?.cornerCurve = .continuous
        previewImageView.layer?.masksToBounds = true
        let documentClip = NSView()
        documentClip.addManaged(previewImageView)
        scrollView.documentView = documentClip

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)

        let controls = makeControlStack()

        view.addManaged(header)
        view.addManaged(scrollView)
        view.addManaged(spinner)
        view.addManaged(controls)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: DesignSystem.Spacing.l),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignSystem.Spacing.m),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            scrollView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -DesignSystem.Spacing.l),

            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -DesignSystem.Spacing.l),

            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            documentClip.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            previewImageView.topAnchor.constraint(equalTo: documentClip.topAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: documentClip.bottomAnchor),
            previewImageView.centerXAnchor.constraint(equalTo: documentClip.centerXAnchor),
            previewImageView.widthAnchor.constraint(lessThanOrEqualTo: documentClip.widthAnchor),
        ])
    }

    private func makeControlStack() -> NSView {
        for theme in PostcardTheme.ordered {
            let swatch = PostcardSwatch(theme: theme, selected: theme == self.theme)
            swatch.onTap = { [weak self] in self?.select(theme) }
            swatches[theme] = swatch
            swatchRow.addArrangedSubview(swatch)
        }
        swatchRow.orientation = .horizontal
        swatchRow.spacing = DesignSystem.Spacing.s
        swatchRow.alignment = .centerY

        nameToggle.state = options.showsDisplayName ? .on : .off
        nameToggle.target = self
        nameToggle.action = #selector(toggleName)
        metricsToggle.state = options.showsMetrics ? .on : .off
        metricsToggle.target = self
        metricsToggle.action = #selector(toggleMetrics)
        threadToggle.state = options.showsThread ? .on : .off
        threadToggle.target = self
        threadToggle.action = #selector(toggleThread)
        let toggleRow = NSStackView(views: [
            toggleLine(nameToggle), toggleLine(metricsToggle), toggleLine(threadToggle),
        ])
        toggleRow.orientation = .vertical
        toggleRow.spacing = DesignSystem.Spacing.s
        toggleRow.alignment = .leading

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        copy.bezelStyle = .rounded
        let share = NSButton(title: "Share…", target: self, action: #selector(share))
        share.bezelStyle = .rounded
        let actionRow = NSStackView(views: [NSView(), save, copy, share])
        actionRow.orientation = .horizontal
        actionRow.spacing = DesignSystem.Spacing.s
        actionRow.alignment = .centerY

        let stack = NSStackView(views: [swatchRow, toggleRow, actionRow])
        stack.orientation = .vertical
        stack.spacing = DesignSystem.Spacing.m
        stack.alignment = .leading
        stack.distribution = .fill
        NSLayoutConstraint.activate([
            toggleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for line in toggleRow.arrangedSubviews {
            line.widthAnchor.constraint(equalTo: toggleRow.widthAnchor).isActive = true
        }
        return stack
    }

    /// One control row: the checkbox label on the left, the checkbox itself
    /// pinned to the right edge, so labels never truncate and the control never
    /// overlaps them — the macOS read of the iOS vertical toggle list.
    private func toggleLine(_ checkbox: NSButton) -> NSStackView {
        let label = NSTextField(labelWithString: checkbox.title)
        label.font = DesignSystem.Typography.body()
        label.textColor = DesignSystem.Color.label
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        checkbox.title = ""
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, NSView(), checkbox])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DesignSystem.Spacing.s
        return row
    }

    // MARK: - Image loading

    private func loadImagesThenRender() {
        let scale = max(view.window?.backingScaleFactor ?? 2, 2)
        Task { [weak self] in
            guard let self else { return }
            async let avatar = Self.loadAvatar(self.tweet, scale: scale)
            async let photos = Self.loadPhotos(self.tweet, scale: scale)
            self.avatar = await avatar
            self.photos = await photos
            self.spinner.stopAnimation(nil)
            self.rebuildPreview()
        }
    }

    private static func loadAvatar(_ tweet: Tweet, scale: CGFloat) async -> NSImage? {
        guard AppSettings.imagesEnabled, let url = tweet.author.avatarURL.flatMap(URL.init) else { return nil }
        return await ImageLoader.image(for: url, pointSize: CGSize(width: 120, height: 120), scale: scale)
    }

    /// Loads up to two photo (or video-poster) images, preferring the direct X
    /// CDN URL and falling back to the server media proxy — the same path the
    /// feed uses. Videos contribute their poster frame; polls/cards are skipped.
    private static func loadPhotos(_ tweet: Tweet, scale: CGFloat) async -> [NSImage] {
        guard AppSettings.imagesEnabled else { return [] }
        let targets: [URL] = tweet.media.enumerated().compactMap { index, media in
            switch media.kind {
            case .photo, .video, .animatedGif:
                return URL(string: media.url) ?? AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: index)
            default:
                return nil
            }
        }
        var images: [NSImage] = []
        for url in targets.prefix(2) {
            if let image = await ImageLoader.image(for: url, pointSize: CGSize(width: 1080, height: 1080), scale: scale) {
                images.append(image)
            }
        }
        return images
    }

    // MARK: - Preview

    /// The blocks the postcard renders: the full root→focal chain when Thread is
    /// on and fetched, else just the focal tweet (default, unchanged behavior).
    private var activeEntries: [PostcardView.Entry] {
        let single = PostcardView.Entry(tweet: tweet, avatar: avatar, photos: photos)
        return (options.showsThread ? threadEntries : nil) ?? [single]
    }

    private func rebuildPreview() {
        previewImageView.image = renderedImage()
    }

    private func renderedImage() -> NSImage {
        let card = PostcardView(entries: activeEntries, theme: theme, options: options)
        card.appearance = view.effectiveAppearance
        return card.render(scale: Self.renderScale)
    }

    // MARK: - Actions

    private func select(_ theme: PostcardTheme) {
        guard theme != self.theme else { return }
        swatches[self.theme]?.setSelected(false)
        self.theme = theme
        PostcardStore.lastTheme = theme
        swatches[theme]?.setSelected(true)
        rebuildPreview()
    }

    @objc private func toggleName() {
        options.showsDisplayName = nameToggle.state == .on
        rebuildPreview()
    }

    @objc private func toggleMetrics() {
        options.showsMetrics = metricsToggle.state == .on
        rebuildPreview()
    }

    /// Turning Thread on stacks the root→focal chain. The chain is fetched once
    /// and cached, so re-toggling (or changing theme / name / metrics) never
    /// refetches.
    @objc private func toggleThread() {
        options.showsThread = threadToggle.state == .on
        if options.showsThread, threadEntries == nil, !threadLoading {
            fetchThread()
        } else {
            rebuildPreview()
        }
    }

    private func fetchThread() {
        threadLoading = true
        spinner.startAnimation(nil)
        Task { [weak self] in
            guard let self else { return }
            let entries = await Self.loadThreadEntries(focal: self.tweet)
            self.threadLoading = false
            self.spinner.stopAnimation(nil)
            guard self.options.showsThread else { return }
            self.threadEntries = entries
            self.rebuildPreview()
        }
    }

    /// Fetches the thread and walks the parent chain from the focal tweet up to
    /// the root (cap 20, mirroring the TUI), then loads each tweet's avatar and
    /// photos. Falls back to the focal alone if the fetch fails.
    private static func loadThreadEntries(focal: Tweet) async -> [PostcardView.Entry] {
        let chain: [Tweet]
        if let thread = try? await AppEnvironment.shared.api.thread(id: focal.restID) {
            chain = ancestorChain(focal: thread.focal ?? focal, ancestors: thread.ancestors)
        } else {
            chain = [focal]
        }
        var entries: [PostcardView.Entry] = []
        for tweet in chain {
            async let avatar = loadAvatar(tweet, scale: Self.renderScale)
            async let photos = loadPhotos(tweet, scale: Self.renderScale)
            entries.append(PostcardView.Entry(tweet: tweet, avatar: await avatar, photos: await photos))
        }
        return entries
    }

    /// Climbs `inReplyToTweetID` from the focal tweet to the root, returning
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

    @objc private func save() {
        let image = renderedImage()
        guard let png = Self.pngData(image) else {
            AppLogger.shared.warn("postcard png encode failed", category: .media)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(tweet.author.handle)-\(tweet.restID)-postcard.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
                AppLogger.shared.info("saved postcard to \(url.lastPathComponent)", category: .media)
            } catch {
                AppLogger.shared.warn("save postcard failed: \(error)", category: .media)
            }
        }
    }

    @objc private func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([renderedImage()])
    }

    @objc private func share(_ sender: NSButton) {
        let picker = NSSharingServicePicker(items: [renderedImage()])
        let rect = NSRect(x: sender.bounds.midX, y: sender.bounds.minY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: sender, preferredEdge: .minY)
    }

    @objc private func close() {
        presentingViewController?.dismiss(self)
    }

    /// Encodes an `NSImage`'s bitmap representation to PNG, preserving the full
    /// pixel resolution of the rendered card.
    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// A tappable circular theme swatch showing the theme's background and accent.
private final class PostcardSwatch: NSControl {
    static let size: CGFloat = 36

    var onTap: (() -> Void)?
    private let theme: PostcardTheme
    private let gradient = CAGradientLayer()
    private let ring = CALayer()
    private let accentDot = CALayer()
    private var selected = false

    init(theme: PostcardTheme, selected: Bool) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        toolTip = theme.title
        widthAnchor.constraint(equalToConstant: Self.size).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size).isActive = true

        gradient.colors = [theme.background.cgColor, (theme.backgroundEnd ?? theme.background).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.cornerRadius = Self.size / 2
        layer?.addSublayer(gradient)

        ring.borderWidth = 3
        ring.cornerRadius = Self.size / 2
        layer?.addSublayer(ring)

        accentDot.backgroundColor = theme.accent.cgColor
        accentDot.cornerRadius = 5
        layer?.addSublayer(accentDot)

        setSelected(selected)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        ring.frame = bounds
        let dot: CGFloat = 10
        accentDot.frame = NSRect(x: (bounds.width - dot) / 2, y: (bounds.height - dot) / 2, width: dot, height: dot)
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        ring.borderColor = selected ? DesignSystem.Color.accent.cgColor : DesignSystem.Color.separator.cgColor
        accentDot.isHidden = !selected
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }
}

/// Persists the last-picked postcard theme so it survives across presentations.
enum PostcardStore {
    private static let key = "unrager.postcardTheme"
    static var lastTheme: PostcardTheme {
        get { PostcardTheme(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .glass }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
