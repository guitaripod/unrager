import AppKit
import UniformTypeIdentifiers
import UnragerKit

/// Compose a new tweet or a reply. A text view with a 280-char counter, a
/// drag-drop / file-picker image attachment strip, and a Post button.
@MainActor
final class ComposeViewController: NSViewController, NSTextViewDelegate {
    enum Mode {
        case new
        case reply(to: Tweet)
    }

    var onPosted: (() -> Void)?

    private let mode: Mode
    private let limit = 280
    private let maxAttachments = 4

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let counterLabel = NSTextField(labelWithString: "280")
    private let postButton = NSButton(title: "Open in X", target: nil, action: nil)
    private let attachButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let attachmentStrip = NSStackView()

    private struct Attachment {
        let media: ComposeMedia
        let image: NSImage
    }

    private var attachments: [Attachment] = []

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = DropView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))
        container.onDrop = { [weak self] urls in self?.addFiles(urls) }
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true

        switch mode {
        case .new: titleLabel.stringValue = "New Tweet"
        case let .reply(tweet): titleLabel.stringValue = "Reply to @\(tweet.author.handle)"
        }
        titleLabel.font = DesignSystem.Typography.name()
        titleLabel.textColor = DesignSystem.Color.label

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        postButton.bezelStyle = .rounded
        postButton.keyEquivalent = "\r"
        postButton.target = self
        postButton.action = #selector(post)
        postButton.isEnabled = false
        postButton.contentTintColor = DesignSystem.Color.accent

        attachButton.bezelStyle = .toolbar
        attachButton.image = DesignSystem.icon("photo.on.rectangle", pointSize: 15)
        attachButton.target = self
        attachButton.action = #selector(attach)
        attachButton.toolTip = "Attach images"
        attachButton.setAccessibilityLabel("Attach images")

        counterLabel.font = DesignSystem.Typography.metric()
        counterLabel.textColor = DesignSystem.Color.secondaryLabel
        counterLabel.alignment = .right

        textView.delegate = self
        textView.font = DesignSystem.Typography.body()
        textView.textColor = DesignSystem.Color.label
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DesignSystem.Color.surface

        attachmentStrip.orientation = .horizontal
        attachmentStrip.spacing = DesignSystem.Spacing.s
        attachmentStrip.alignment = .centerY
        attachmentStrip.isHidden = true

        let header = NSStackView(views: [titleLabel, NSView()])
        header.orientation = .horizontal

        let footer = NSStackView(views: [attachButton, counterLabel, NSView(), cancelButton, postButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = DesignSystem.Spacing.s

        view.addManaged(header)
        view.addManaged(scrollView)
        view.addManaged(attachmentStrip)
        view.addManaged(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: DesignSystem.Spacing.l),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignSystem.Spacing.s),
            scrollView.bottomAnchor.constraint(equalTo: attachmentStrip.topAnchor, constant: -DesignSystem.Spacing.s),

            attachmentStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            attachmentStrip.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            attachmentStrip.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -DesignSystem.Spacing.s),
            attachmentStrip.heightAnchor.constraint(equalToConstant: 64),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -DesignSystem.Spacing.l),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        updatePostState()
    }

    private func updatePostState() {
        let count = textView.string.count
        let remaining = limit - count
        counterLabel.stringValue = String(remaining)
        counterLabel.textColor = remaining < 0 ? .systemRed : DesignSystem.Color.secondaryLabel
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        postButton.isEnabled = !trimmed.isEmpty && count <= limit
        attachButton.isEnabled = attachments.count < maxAttachments
    }

    // MARK: - Attachments

    @objc private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .gif, .png, .jpeg]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addFiles(panel.urls)
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls where attachments.count < maxAttachments {
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            let media = ComposeMedia(data: data, filename: url.lastPathComponent, mimeType: mime)
            attachments.append(Attachment(media: media, image: image))
        }
        rebuildStrip()
        updatePostState()
    }

    private func rebuildStrip() {
        attachmentStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        attachmentStrip.isHidden = attachments.isEmpty
        for (index, attachment) in attachments.enumerated() {
            attachmentStrip.addArrangedSubview(AttachmentThumb(image: attachment.image, index: index) { [weak self] i in
                self?.removeAttachment(at: i)
            })
        }
    }

    private func removeAttachment(at index: Int) {
        guard index < attachments.count else { return }
        attachments.remove(at: index)
        rebuildStrip()
        updatePostState()
    }

    // MARK: - Post

    /// unrager never posts. The composed text is copied to the clipboard and X
    /// is opened with a prefilled compose intent (the clipboard is the backup),
    /// mirroring the TUI's open-X behavior. Replies pass `in_reply_to`.
    @objc private func post() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        openInX(text: text)
        onPosted?()
        dismiss(self)
    }

    /// Hands the draft to the real X app. A reply opens the parent tweet in-app
    /// so the reply lands in the right thread (matching the TUI — the X URL
    /// scheme can't prefill a reply composer); a new tweet opens the composer
    /// prefilled. Web URL is the fallback when no app handles the scheme.
    private func openInX(text: String) {
        let appURL: URL?
        let webURL: URL?
        switch mode {
        case let .reply(tweet):
            appURL = URL(string: "twitter://status?id=\(tweet.restID)")
            webURL = URL(string: tweet.url)
        default:
            var components = URLComponents(string: "twitter://post")
            components?.queryItems = [URLQueryItem(name: "message", value: text)]
            appURL = components?.url
            webURL = Self.intentURL(text: text, mode: mode)
        }
        if let appURL, NSWorkspace.shared.urlForApplication(toOpen: appURL) != nil {
            NSWorkspace.shared.open(appURL)
            return
        }
        if let webURL { NSWorkspace.shared.open(webURL) }
    }

    /// Builds `https://x.com/intent/post?text=…(&in_reply_to=…)`.
    private static func intentURL(text: String, mode: Mode) -> URL? {
        var components = URLComponents(string: "https://x.com/intent/post")
        var items = [URLQueryItem(name: "text", value: text)]
        if case let .reply(tweet) = mode {
            items.append(URLQueryItem(name: "in_reply_to", value: tweet.restID))
        }
        components?.queryItems = items
        return components?.url
    }

    @objc private func cancel() {
        dismiss(self)
    }
}

/// A small image thumbnail with a remove button, shown in the compose
/// attachment strip.
private final class AttachmentThumb: NSView {
    private let onRemove: (Int) -> Void
    private let index: Int

    init(image: NSImage, index: Int, onRemove: @escaping (Int) -> Void) {
        self.index = index
        self.onRemove = onRemove
        super.init(frame: .zero)
        wantsLayer = true

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.setAccessibilityLabel("Attached image \(index + 1)")
        addManaged(imageView)

        let remove = NSButton()
        remove.bezelStyle = .circular
        remove.image = DesignSystem.icon("xmark.circle.fill", pointSize: 14)
        remove.isBordered = false
        remove.contentTintColor = .white
        remove.target = self
        remove.action = #selector(removeTapped)
        remove.setAccessibilityLabel("Remove attachment")
        addManaged(remove)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 60),
            heightAnchor.constraint(equalToConstant: 60),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 56),
            imageView.heightAnchor.constraint(equalToConstant: 56),
            remove.topAnchor.constraint(equalTo: topAnchor),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func removeTapped() { onRemove(index) }
}

/// A container view that accepts file drags and reports dropped file URLs.
private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else {
            return false
        }
        onDrop?(urls)
        return true
    }
}
