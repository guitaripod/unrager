import AppKit
import AVFoundation
import UnragerKit

/// Renders a tweet's full media payload: single image, a 2×2 image grid, a
/// video / animated GIF poster (tap opens the native player), poll bars, and
/// link / article / broadcast / YouTube cards. Built once and reconfigured per
/// tweet; all transient state (image loads) is torn down in `reset()` so the
/// host cell can reuse it safely.
final class TweetMediaView: NSView {
    /// Photo grid tapped — opens the zoomable gallery (index of the tapped tile).
    var onTapPhoto: ((Int) -> Void)?
    /// Inline video / animated GIF tapped — opens the native full-window player.
    var onTapVideo: (() -> Void)?
    /// Poll tapped — opens the thread (polls have no dedicated viewer).
    var onTapPoll: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?

    private let imageGrid = ImageGridView()
    private let videoView = InlineVideoView()
    private let pollView = PollView()
    private let cardView = LinkCardView()

    private var active: NSView?
    private var heightConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true
        for child in [imageGrid, videoView, pollView, cardView] as [NSView] {
            child.isHidden = true
            addManaged(child)
            child.pinEdges(to: self)
        }
        imageGrid.onTap = { [weak self] index in self?.onTapPhoto?(index) }
        cardView.onOpen = { [weak self] url in self?.onOpenURL?(url) }
        videoView.onTap = { [weak self] in self?.onTapVideo?() }
        pollView.onTap = { [weak self] in self?.onTapPoll?() }
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
    }

    /// True if the tweet carries any renderable media. The host uses this to
    /// show / hide the whole view in its column stack.
    static func hasMedia(_ tweet: Tweet) -> Bool { !tweet.media.isEmpty }

    func reset() {
        videoView.stop()
        imageGrid.cancel()
        cardView.cancel()
        active?.isHidden = true
        active = nil
    }

    func configure(with tweet: Tweet, api: APIClient, imagesEnabled: Bool, contentWidth: CGFloat) {
        reset()
        guard let first = tweet.media.first else {
            heightConstraint.constant = 0
            return
        }

        switch first.kind {
        case .poll(let options, let endsAt, let countsFinal):
            show(pollView)
            pollView.configure(options: options, endsAt: endsAt, countsFinal: countsFinal)
            heightConstraint.constant = pollView.intrinsicHeight(width: contentWidth)

        case .video, .animatedGif:
            show(videoView)
            let height = mediaHeight(for: contentWidth, aspectRatio: first.aspectRatio)
            heightConstraint.constant = height
            videoView.configure(
                tweet: tweet, media: first, api: api,
                imagesEnabled: imagesEnabled,
                size: CGSize(width: contentWidth, height: height))

        case .youTube:
            show(cardView)
            cardView.configureYouTube(media: first, imagesEnabled: imagesEnabled, width: contentWidth)
            heightConstraint.constant = cardView.intrinsicHeight(width: contentWidth)

        case .linkCard(let title, let description, let domain, let targetURL):
            show(cardView)
            cardView.configureLink(media: first, title: title, description: description,
                                   domain: domain, targetURL: targetURL,
                                   imagesEnabled: imagesEnabled, width: contentWidth)
            heightConstraint.constant = cardView.intrinsicHeight(width: contentWidth)

        case .article(_, let title, let previewText):
            show(cardView)
            cardView.configureArticle(media: first, title: title, previewText: previewText,
                                      targetURL: tweet.url, imagesEnabled: imagesEnabled, width: contentWidth)
            heightConstraint.constant = cardView.intrinsicHeight(width: contentWidth)

        case .broadcast(_, let title, let broadcaster, let isLive):
            show(cardView)
            cardView.configureBroadcast(media: first, title: title, broadcaster: broadcaster,
                                        isLive: isLive, targetURL: tweet.url,
                                        imagesEnabled: imagesEnabled, width: contentWidth)
            heightConstraint.constant = cardView.intrinsicHeight(width: contentWidth)

        case .photo:
            let photos = tweet.media.filter { if case .photo = $0.kind { return true } else { return false } }
            show(imageGrid)
            imageGrid.configure(photos: photos.isEmpty ? [first] : photos,
                                imagesEnabled: imagesEnabled, width: contentWidth)
            heightConstraint.constant = imageGrid.intrinsicHeight(width: contentWidth)
        }
    }

    private func show(_ view: NSView) {
        active = view
        view.isHidden = false
    }

    /// Sizes the inline video/GIF box to the clip's real aspect (width ÷
    /// height), clamped so it's neither a thin strip nor a screen-eating column.
    /// Falls back to 16:9 when the server didn't report dimensions.
    private func mediaHeight(for width: CGFloat, aspectRatio: CGFloat?) -> CGFloat {
        let ratio = (aspectRatio.map { $0 > 0 ? $0 : 16.0 / 9.0 }) ?? (16.0 / 9.0)
        let clamped = min(max(ratio, 1.0 / 1.3), 2.0)
        return max(160, (width / clamped).rounded())
    }
}

// MARK: - Image grid (single image or 2×2)

/// Renders 1–4 photos: one full-width image, or a 2-up / 3-up / 2×2 grid with
/// a "+N" overlay when there are more than four attachments.
private final class ImageGridView: NSView {
    var onTap: ((Int) -> Void)?

    private var tiles: [AsyncImageView] = []
    private var photos: [Media] = []
    private let overflowLabel = NSTextField(labelWithString: "")
    private let gap = DesignSystem.Spacing.xxs
    private var tapRecognizer: NSClickGestureRecognizer!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        overflowLabel.font = .systemFont(ofSize: 22, weight: .heavy)
        overflowLabel.textColor = .white
        overflowLabel.alignment = .center
        overflowLabel.isHidden = true
        tapRecognizer = NSClickGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tapRecognizer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func cancel() {
        tiles.forEach { $0.cancel() }
    }

    /// A lone photo gets its true aspect (clamped to a wide-panorama floor and a
    /// portrait ceiling); a grid stays 16:9. Falls back to 16:9 when dimensions
    /// are unknown.
    func intrinsicHeight(width: CGFloat) -> CGFloat {
        if photos.count == 1, let ratio = photos[0].aspectRatio, ratio > 0 {
            let natural = width / ratio
            return min(max(natural, width * 0.5), width * 1.3).rounded()
        }
        return max(160, (width * 9 / 16).rounded())
    }

    func configure(photos: [Media], imagesEnabled: Bool, width: CGFloat) {
        self.photos = photos
        rebuildTiles(count: min(photos.count, 4))
        let height = intrinsicHeight(width: width)
        layoutTiles(count: tiles.count, width: width, height: height)

        for (index, tile) in tiles.enumerated() {
            guard imagesEnabled, index < photos.count, let url = URL(string: photos[index].url) else {
                tile.cancel()
                continue
            }
            let size = tile.bounds.size == .zero
                ? CGSize(width: width / 2, height: height / 2) : tile.bounds.size
            tile.load(url: url, targetSize: size)
            tile.setAccessibilityLabel(photos[index].altText ?? "Photo")
        }

        if photos.count > 4 {
            overflowLabel.isHidden = false
            overflowLabel.stringValue = "+\(photos.count - 4)"
            tiles.last?.applyLayerBackground(NSColor(white: 0, alpha: 0.45))
        } else {
            overflowLabel.isHidden = true
        }
    }

    private func rebuildTiles(count: Int) {
        guard tiles.count != count else { return }
        tiles.forEach { $0.removeFromSuperview() }
        overflowLabel.removeFromSuperview()
        tiles = (0..<max(1, count)).map { _ in
            let view = AsyncImageView()
            view.setRounded(DesignSystem.Radius.media)
            view.setFill()
            addManaged(view)
            return view
        }
        addManaged(overflowLabel)
    }

    private func layoutTiles(count: Int, width: CGFloat, height: CGFloat) {
        NSLayoutConstraint.deactivate(constraints)
        let g = gap
        switch count {
        case 1:
            pin(tiles[0], x: 0, y: 0, w: width, h: height)
        case 2:
            let w = (width - g) / 2
            pin(tiles[0], x: 0, y: 0, w: w, h: height)
            pin(tiles[1], x: w + g, y: 0, w: w, h: height)
        case 3:
            let w = (width - g) / 2
            let h = (height - g) / 2
            pin(tiles[0], x: 0, y: 0, w: w, h: height)
            pin(tiles[1], x: w + g, y: h + g, w: w, h: h)
            pin(tiles[2], x: w + g, y: 0, w: w, h: h)
        default:
            let w = (width - g) / 2
            let h = (height - g) / 2
            pin(tiles[0], x: 0, y: h + g, w: w, h: h)
            pin(tiles[1], x: w + g, y: h + g, w: w, h: h)
            pin(tiles[2], x: 0, y: 0, w: w, h: h)
            pin(tiles[3], x: w + g, y: 0, w: w, h: h)
        }
        if let last = tiles.last {
            NSLayoutConstraint.activate([
                overflowLabel.centerXAnchor.constraint(equalTo: last.centerXAnchor),
                overflowLabel.centerYAnchor.constraint(equalTo: last.centerYAnchor),
            ])
        }
    }

    /// Pins a tile by top-left origin (AppKit's y grows upward, so `y` is the
    /// distance from the bottom).
    private func pin(_ tile: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x),
            tile.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -y),
            tile.widthAnchor.constraint(equalToConstant: max(1, w)),
            tile.heightAnchor.constraint(equalToConstant: max(1, h)),
        ])
    }

    @objc private func tapped(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: self)
        let index = tiles.firstIndex { $0.frame.contains(point) } ?? 0
        onTap?(index)
    }
}

// MARK: - Inline video / animated GIF

/// Plays a tweet's video / animated GIF inline: muted autoplay, looping forever,
/// scaled to fit (letterboxed, never cropped) via an `AVPlayerLayer` with
/// `videoGravity = .resizeAspect`. A poster image covers the surface until the
/// first frame is ready. Tapping fires `onTap`, which opens the full-window
/// native player. `stop()` tears the player down so a recycled cell never plays
/// the previous tweet's clip.
private final class InlineVideoView: NSView, NSGestureRecognizerDelegate {
    var onTap: (() -> Void)?

    /// Session-wide inline-audio preference. Inline clips autoplay muted (like X);
    /// clicking any clip's speaker unmutes them all for the session. Resets to
    /// muted on relaunch. Mirrors the iOS `MediaPlayerView.audioEnabled`.
    static var audioEnabled = false

    private let playerLayer = AVPlayerLayer()
    private let poster = AsyncImageView()
    private let gifLabel = NSTextField(labelWithString: "GIF")
    private let muteButton = NSButton()
    private var player: AVPlayer?
    private var isGif = false
    private var statusObservation: NSKeyValueObservation?
    private nonisolated(unsafe) var loopObserver: (any NSObjectProtocol)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Radius.media
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)

        poster.setFit()
        poster.placeholderColor = DesignSystem.Color.surface
        addManaged(poster)
        poster.pinEdges(to: self)

        gifLabel.font = .systemFont(ofSize: 11, weight: .heavy)
        gifLabel.textColor = .white
        gifLabel.wantsLayer = true
        gifLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        gifLabel.layer?.cornerRadius = 4
        gifLabel.alignment = .center
        gifLabel.isHidden = true
        addManaged(gifLabel)

        muteButton.isBordered = false
        muteButton.bezelStyle = .circular
        muteButton.wantsLayer = true
        muteButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        muteButton.layer?.cornerRadius = 14
        muteButton.contentTintColor = .white
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        muteButton.isHidden = true
        muteButton.setAccessibilityLabel("Toggle sound")
        addManaged(muteButton)
        updateMuteIcon()

        NSLayoutConstraint.activate([
            gifLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignSystem.Spacing.s),
            gifLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignSystem.Spacing.s),
            gifLabel.widthAnchor.constraint(equalToConstant: 34),
            gifLabel.heightAnchor.constraint(equalToConstant: 18),
            muteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignSystem.Spacing.s),
            muteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignSystem.Spacing.s),
            muteButton.widthAnchor.constraint(equalToConstant: 28),
            muteButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    /// Keeps the open-full-screen tap from firing when the click lands on the
    /// mute button, so toggling sound never also opens the player.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard !muteButton.isHidden else { return true }
        let point = muteButton.convert(event.locationInWindow, from: nil)
        return !muteButton.bounds.contains(point)
    }

    /// Flips the session-wide inline-audio preference and applies it to the live
    /// player. macOS has no audio session, so only the mute property is touched.
    @objc private func toggleMute() {
        Self.audioEnabled.toggle()
        player?.isMuted = isGif || !Self.audioEnabled
        updateMuteIcon()
    }

    private func updateMuteIcon() {
        let symbol = Self.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
        muteButton.image = DesignSystem.icon(symbol, pointSize: 12, weight: .semibold)
    }

    func configure(tweet: Tweet, media: Media, api: APIClient, imagesEnabled: Bool, size: CGSize) {
        stop()
        let isGif = { if case .animatedGif = media.kind { return true } else { return false } }()
        self.isGif = isGif
        gifLabel.isHidden = !isGif
        muteButton.isHidden = isGif
        updateMuteIcon()
        if imagesEnabled, let url = URL(string: media.url), !media.url.isEmpty {
            poster.load(url: url, targetSize: size)
        } else {
            poster.image = nil
        }
        poster.setAccessibilityLabel(media.altText ?? (isGif ? "Animated GIF" : "Video"))
        setAccessibilityRole(.button)

        let videoURL = media.videoURL.flatMap(URL.init)
            ?? api.mediaURL(tweetID: tweet.restID, index: indexOfVideo(in: tweet))
        let player = AVPlayer(url: videoURL)
        player.isMuted = isGif || !Self.audioEnabled
        player.actionAtItemEnd = .none
        self.player = player
        playerLayer.player = player

        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .readyToPlay else { return }
            Task { @MainActor in self?.revealVideo() }
        }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        player.play()
    }

    private func revealVideo() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            poster.animator().alphaValue = 0
        }
    }

    private func indexOfVideo(in tweet: Tweet) -> Int {
        tweet.media.firstIndex(where: { $0.isVideo }) ?? 0
    }

    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        player?.pause()
        player = nil
        playerLayer.player = nil
        poster.cancel()
        poster.alphaValue = 1
        muteButton.isHidden = true
    }

    deinit {
        statusObservation?.invalidate()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }

    @objc private func tapped() { onTap?() }
}

// MARK: - Poll

/// Renders poll options as horizontal bars with a leading fill proportional to
/// each option's share, the option label, and the vote count / percentage. A
/// footer shows total votes and the "final" / "ends" state.
private final class PollView: NSView {
    var onTap: (() -> Void)?

    private let stack = NSStackView()
    private let footer = NSTextField(labelWithString: "")
    private var bars: [PollBar] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignSystem.Spacing.s
        addManaged(stack)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))
        footer.font = DesignSystem.Typography.caption()
        footer.textColor = DesignSystem.Color.secondaryLabel
        addManaged(footer)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: DesignSystem.Spacing.xs),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func intrinsicHeight(width: CGFloat) -> CGFloat {
        CGFloat(bars.count) * (28 + DesignSystem.Spacing.s) + 20
    }

    func configure(options: [PollOption], endsAt: Date?, countsFinal: Bool) {
        bars.forEach { $0.removeFromSuperview() }
        bars.removeAll()
        let total = max(1, options.reduce(0) { $0 + $1.count })
        let leader = options.max(by: { $0.count < $1.count })?.count ?? 0
        for option in options {
            let bar = PollBar()
            let fraction = Double(option.count) / Double(total)
            bar.configure(label: option.label, fraction: fraction,
                          percent: Int((fraction * 100).rounded()),
                          isLeader: option.count == leader && leader > 0)
            stack.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            bars.append(bar)
        }
        let totalVotes = options.reduce(0) { $0 + $1.count }
        var parts = ["\(Format.count(totalVotes)) vote\(totalVotes == 1 ? "" : "s")"]
        if countsFinal {
            parts.append("Final results")
        } else if let endsAt {
            parts.append(endsAt <= Date() ? "Final results" : "ends \(Format.relativeTime(endsAt))")
        }
        footer.stringValue = parts.joined(separator: " · ")
    }

    @objc private func tapped() { onTap?() }
}

/// A single poll option bar.
private final class PollBar: NSView {
    private let fill = NSView()
    private let labelField = NSTextField(labelWithString: "")
    private let percentField = NSTextField(labelWithString: "")
    private var fillWidth: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Radius.control
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        applyLayerBackground(DesignSystem.Color.surface)

        fill.wantsLayer = true
        fill.layer?.cornerRadius = DesignSystem.Radius.control
        fill.layer?.cornerCurve = .continuous
        addManaged(fill)

        labelField.font = DesignSystem.Typography.body()
        labelField.textColor = DesignSystem.Color.label
        labelField.lineBreakMode = .byTruncatingTail
        addManaged(labelField)

        percentField.font = DesignSystem.Typography.metric()
        percentField.textColor = DesignSystem.Color.secondaryLabel
        addManaged(percentField)

        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            fillWidth,
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignSystem.Spacing.s),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignSystem.Spacing.s),
            percentField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: percentField.leadingAnchor, constant: -DesignSystem.Spacing.s),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var fraction: Double = 0

    func configure(label: String, fraction: Double, percent: Int, isLeader: Bool) {
        self.fraction = fraction
        labelField.stringValue = label
        percentField.stringValue = "\(percent)%"
        let color = isLeader ? DesignSystem.Color.accent : DesignSystem.Color.secondaryLabel
        fill.applyLayerBackground(color.withAlphaComponent(isLeader ? 0.28 : 0.16))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fillWidth.constant = max(0, bounds.width * CGFloat(fraction))
    }
}

// MARK: - Link / article / broadcast / YouTube card

/// A horizontal media card: a leading thumbnail, a title, a secondary line
/// (description / domain / broadcaster), and an optional badge (a play glyph
/// for YouTube, a red "● LIVE" pill for live broadcasts). Tapping opens the
/// target URL.
private final class LinkCardView: NSView {
    var onOpen: ((URL) -> Void)?

    private let thumbnail = AsyncImageView()
    private let badge = NSView()
    private let badgeIcon = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var targetURL: URL?
    private var thumbnailWidth: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = DesignSystem.Radius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        updateBorder()

        thumbnail.setFill()
        thumbnail.placeholderColor = DesignSystem.Color.surface
        addManaged(thumbnail)

        badge.wantsLayer = true
        badge.layer?.cornerRadius = DesignSystem.Radius.pill
        badge.layer?.masksToBounds = true
        badge.isHidden = true
        badgeIcon.contentTintColor = .white
        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textColor = .white
        let badgeStack = NSStackView(views: [badgeIcon, badgeLabel])
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 3
        badgeStack.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)
        badge.addManaged(badgeStack)
        badgeStack.pinEdges(to: badge)
        addManaged(badge)

        titleLabel.font = DesignSystem.Typography.name()
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = DesignSystem.Typography.metric()
        subtitleLabel.textColor = DesignSystem.Color.secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let textColumn = NSStackView(views: [titleLabel, subtitleLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = DesignSystem.Spacing.xxs
        addManaged(textColumn)

        thumbnailWidth = thumbnail.widthAnchor.constraint(equalToConstant: 96)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnail.topAnchor.constraint(equalTo: topAnchor),
            thumbnail.bottomAnchor.constraint(equalTo: bottomAnchor),
            thumbnailWidth,
            badge.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: DesignSystem.Spacing.xs),
            badge.bottomAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: -DesignSystem.Spacing.xs),
            textColumn.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: DesignSystem.Spacing.m),
            textColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignSystem.Spacing.m),
            textColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    func cancel() {
        thumbnail.cancel()
    }

    func intrinsicHeight(width: CGFloat) -> CGFloat { 96 }

    func configureLink(media: Media, title: String, description: String, domain: String,
                       targetURL: String, imagesEnabled: Bool, width: CGFloat) {
        configureCommon(thumbURL: media.url, imagesEnabled: imagesEnabled)
        titleLabel.stringValue = title.isEmpty ? domain : title
        subtitleLabel.stringValue = domain
        hideBadge()
        self.targetURL = URL(string: targetURL)
        setAccessibilityLabel("Link card: \(title)")
    }

    func configureArticle(media: Media, title: String, previewText: String, targetURL: String,
                          imagesEnabled: Bool, width: CGFloat) {
        configureCommon(thumbURL: media.url, imagesEnabled: imagesEnabled)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = previewText.isEmpty ? "Article" : previewText
        showBadge(icon: "doc.richtext", text: "ARTICLE", color: DesignSystem.Color.accent)
        self.targetURL = URL(string: targetURL)
        setAccessibilityLabel("Article: \(title)")
    }

    func configureBroadcast(media: Media, title: String, broadcaster: String, isLive: Bool,
                            targetURL: String, imagesEnabled: Bool, width: CGFloat) {
        configureCommon(thumbURL: media.url, imagesEnabled: imagesEnabled)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = broadcaster
        if isLive {
            showBadge(icon: "circle.fill", text: "LIVE", color: DesignSystem.Color.live)
        } else {
            showBadge(icon: "play.fill", text: "REPLAY", color: DesignSystem.Color.accent)
        }
        self.targetURL = URL(string: targetURL)
        setAccessibilityLabel("\(isLive ? "Live broadcast" : "Broadcast"): \(title) by \(broadcaster)")
    }

    func configureYouTube(media: Media, imagesEnabled: Bool, width: CGFloat) {
        configureCommon(thumbURL: media.url, imagesEnabled: imagesEnabled)
        titleLabel.stringValue = "Watch on YouTube"
        subtitleLabel.stringValue = "youtube.com"
        showBadge(icon: "play.fill", text: "YOUTUBE", color: NSColor(red: 1, green: 0, blue: 0, alpha: 1))
        if case .youTube(let videoID) = media.kind {
            self.targetURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")
        }
        setAccessibilityLabel("YouTube video")
    }

    private func configureCommon(thumbURL: String, imagesEnabled: Bool) {
        if imagesEnabled, let url = URL(string: thumbURL), !thumbURL.isEmpty {
            thumbnailWidth.constant = 96
            thumbnail.isHidden = false
            thumbnail.load(url: url, targetSize: CGSize(width: 96, height: 96))
        } else {
            thumbnailWidth.constant = 0
            thumbnail.isHidden = true
            thumbnail.cancel()
        }
    }

    private func showBadge(icon: String, text: String, color: NSColor) {
        badge.isHidden = false
        badge.applyLayerBackground(color)
        badgeIcon.image = DesignSystem.icon(icon, pointSize: 8, weight: .bold)
        badgeLabel.stringValue = text
    }

    private func hideBadge() { badge.isHidden = true }

    override func layout() {
        super.layout()
        updateBorder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        var resolved = DesignSystem.Color.separator.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = DesignSystem.Color.separator.cgColor
        }
        layer?.borderColor = resolved
    }

    @objc private func tapped() {
        if let url = targetURL { onOpen?(url) }
    }
}
