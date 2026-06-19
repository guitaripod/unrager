import AppKit
import AVKit
import UnragerKit

/// A full-window media viewer presented as a sheet over the main window. Photos
/// load at full resolution through the media proxy into a zoomable, pannable
/// `NSScrollView`; multiple photos page with the arrow keys or a segmented
/// control. Esc closes, and Share hands the current image to a
/// `NSSharingServicePicker`. Video / animated GIFs are handled by the sibling
/// `present(videoFor:)` path, which shows an `AVPlayerView`.
@MainActor
final class MediaViewerWindowController: NSWindowController {
    private let tweetID: String
    private let photoIndices: [Int]
    private var page: Int

    private let api = AppEnvironment.shared.api
    private let imageView = NSImageView()
    private let scrollView = NSScrollView()
    private let closeButton = NSButton()
    private let shareButton = NSButton()
    private let pager = NSSegmentedControl()
    private let counterLabel = NSTextField(labelWithString: "")
    private var loadTask: Task<Void, Never>?

    /// Presents a zoomable photo gallery for the tweet's photo attachments,
    /// starting at the tapped photo. No-op if the tweet carries no photos.
    static func presentPhotos(tweetID: String, photoIndices: [Int], startIndex: Int, over parent: NSWindow) {
        guard !photoIndices.isEmpty else { return }
        let controller = MediaViewerWindowController(tweetID: tweetID, photoIndices: photoIndices, startIndex: startIndex)
        controller.present(over: parent)
    }

    /// Presents the native player full-window for a tweet's video / animated GIF.
    static func presentVideo(tweetID: String, mediaIndex: Int, fallbackURL: String?,
                             loops: Bool, over parent: NSWindow) {
        let url = fallbackURL.flatMap(URL.init) ?? AppEnvironment.shared.api.mediaURL(tweetID: tweetID, index: mediaIndex)
        let viewer = VideoViewerWindowController(url: url, loops: loops)
        viewer.present(over: parent)
    }

    private init(tweetID: String, photoIndices: [Int], startIndex: Int) {
        self.tweetID = tweetID
        self.photoIndices = photoIndices
        self.page = min(max(0, startIndex), photoIndices.count - 1)
        let window = MediaViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        super.init(window: window)
        window.escapeHandler = { [weak self] in self?.close() }
        buildContent()
        loadCurrent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func present(over parent: NSWindow) {
        guard let window else { return }
        retainSelf()
        parent.beginSheet(window) { [weak self] _ in self?.releaseSelf() }
    }

    private var selfRetain: MediaViewerWindowController?
    private func retainSelf() { selfRetain = self }
    private func releaseSelf() {
        loadTask?.cancel()
        selfRetain = nil
    }

    override func close() {
        guard let window, let parent = window.sheetParent else { super.close(); return }
        parent.endSheet(window)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 6
        scrollView.documentView = imageView
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        content.addManaged(scrollView)
        scrollView.pinEdges(to: content)

        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipResized),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)

        configureChrome(in: content)
    }

    private func configureChrome(in content: NSView) {
        styleGlassButton(closeButton, symbol: "xmark", action: #selector(closeTapped))
        styleGlassButton(shareButton, symbol: "square.and.arrow.up", action: #selector(shareTapped))

        pager.segmentStyle = .rounded
        pager.trackingMode = .selectOne
        pager.segmentCount = photoIndices.count
        for index in 0..<photoIndices.count { pager.setLabel("\(index + 1)", forSegment: index) }
        pager.selectedSegment = page
        pager.target = self
        pager.action = #selector(pagerChanged)
        pager.isHidden = photoIndices.count <= 1

        counterLabel.font = DesignSystem.Typography.system(12, weight: .semibold)
        counterLabel.textColor = .white
        counterLabel.alignment = .center
        counterLabel.isHidden = photoIndices.count <= 1

        content.addManaged(closeButton)
        content.addManaged(shareButton)
        content.addManaged(pager)
        content.addManaged(counterLabel)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: DesignSystem.Spacing.l),
            closeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignSystem.Spacing.l),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.heightAnchor.constraint(equalToConstant: 34),
            shareButton.topAnchor.constraint(equalTo: closeButton.topAnchor),
            shareButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignSystem.Spacing.l),
            shareButton.widthAnchor.constraint(equalToConstant: 34),
            shareButton.heightAnchor.constraint(equalToConstant: 34),
            pager.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            pager.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -DesignSystem.Spacing.l),
            counterLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            counterLabel.bottomAnchor.constraint(equalTo: pager.topAnchor, constant: -DesignSystem.Spacing.xs),
        ])
        updateCounter()
    }

    private func styleGlassButton(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .circular
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 17
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        button.image = DesignSystem.icon(symbol, pointSize: 14, weight: .semibold)
        button.contentTintColor = .white
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
    }

    private func loadCurrent() {
        loadTask?.cancel()
        imageView.image = nil
        scrollView.magnification = 1
        let url = api.mediaURL(tweetID: tweetID, index: photoIndices[page])
        loadTask = Task { [weak self] in
            let image = await Self.fullResImage(url)
            guard let self, !Task.isCancelled else { return }
            self.imageView.image = image
            self.layoutImage()
        }
        updateCounter()
        pager.selectedSegment = page
    }

    private func layoutImage() {
        imageView.frame = scrollView.contentView.bounds
        scrollView.magnification = 1
    }

    @objc private func clipResized() {
        guard scrollView.magnification == 1 else { return }
        imageView.frame = scrollView.contentView.bounds
    }

    private func updateCounter() {
        counterLabel.stringValue = "\(page + 1) of \(photoIndices.count)"
    }

    fileprivate func step(_ delta: Int) {
        let next = page + delta
        guard next >= 0, next < photoIndices.count else { return }
        page = next
        loadCurrent()
    }

    @objc private func pagerChanged() {
        let selected = pager.selectedSegment
        guard selected >= 0, selected < photoIndices.count, selected != page else { return }
        page = selected
        loadCurrent()
    }

    @objc private func closeTapped() { close() }

    @objc private func shareTapped() {
        let item: Any = imageView.image ?? api.mediaURL(tweetID: tweetID, index: photoIndices[page])
        let picker = NSSharingServicePicker(items: [item])
        let rect = NSRect(x: shareButton.bounds.midX, y: shareButton.bounds.minY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: shareButton, preferredEdge: .minY)
    }

    private static func fullResImage(_ url: URL) async -> NSImage? {
        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        return NSImage(data: data)
    }
}

/// A window that forwards Esc and ⌘W to the controller, and arrow keys to page.
private final class MediaViewerWindow: NSWindow {
    var escapeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { escapeHandler?() }

    override func keyDown(with event: NSEvent) {
        let controller = windowController as? MediaViewerWindowController
        switch event.keyCode {
        case 123: controller?.step(-1)
        case 124: controller?.step(1)
        default: super.keyDown(with: event)
        }
    }
}

/// A full-window native player for tweet video / animated GIF, presented as a
/// sheet. Loops when the source is a GIF; Esc / the close button dismiss it.
@MainActor
private final class VideoViewerWindowController: NSWindowController {
    private let url: URL
    private let loops: Bool
    private var player: AVPlayer?
    private var looper: Any?
    private var selfRetain: VideoViewerWindowController?
    private let playerView = AVPlayerView()
    private let closeButton = NSButton()

    init(url: URL, loops: Bool) {
        self.url = url
        self.loops = loops
        let window = VideoViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        super.init(window: window)
        window.escapeHandler = { [weak self] in self?.close() }
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(over parent: NSWindow) {
        guard let window else { return }
        selfRetain = self
        parent.beginSheet(window) { [weak self] _ in self?.teardown() }
    }

    override func close() {
        guard let window, let parent = window.sheetParent else { super.close(); return }
        parent.endSheet(window)
    }

    private func teardown() {
        player?.pause()
        if let looper { NotificationCenter.default.removeObserver(looper) }
        looper = nil
        player = nil
        playerView.player = nil
        selfRetain = nil
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        let player = AVPlayer(url: url)
        player.isMuted = loops
        self.player = player
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = true
        content.addManaged(playerView)
        playerView.pinEdges(to: content)

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 17
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        closeButton.image = DesignSystem.icon("xmark", pointSize: 14, weight: .semibold)
        closeButton.contentTintColor = .white
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        content.addManaged(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: DesignSystem.Spacing.l),
            closeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignSystem.Spacing.l),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        if loops {
            looper = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem, queue: .main) { [weak player] _ in
                    player?.seek(to: .zero)
                    player?.play()
                }
        }
        player.play()
    }

    @objc private func closeTapped() { close() }
}

private final class VideoViewerWindow: NSWindow {
    var escapeHandler: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { escapeHandler?() }
}
