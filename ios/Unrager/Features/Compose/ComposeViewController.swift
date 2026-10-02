import PhotosUI
import UIKit
import UnragerKit

/// Compose a new tweet, a reply, or a quote — posted through the unrager
/// server (`/api/compose`, `/api/reply/{id}`) so it lands as the signed-in
/// account without bouncing to the X app. Picked photos upload first
/// (`/api/media/upload`, sequential, with per-item progress in the post
/// button) and their minted ids ride along as `media_ids`; a quote carries
/// `quote_tweet_id` and shows a preview card of the quoted tweet. Failures
/// surface an alert with Retry — already-uploaded attachments aren't
/// re-uploaded — and never silently drop media.
final class ComposeViewController: UIViewController {
    enum Mode {
        case new
        case reply(to: Tweet)
        case quote(of: Tweet)
    }

    /// What a successful post did, for the screen that opened the composer.
    struct Posted {
        /// The new post's id.
        let id: String
        /// Whether the reply also liked the post it answers (`autoLikeIfReply`).
        let likedReplyTarget: Bool
    }

    /// Runs on the main actor once a post went through and the composer has
    /// closed, so the presenter can show the reply, fill the heart it liked,
    /// or confirm the post.
    var onPosted: ((Posted) -> Void)?

    private let mode: Mode
    private let drafts = ComposeDraftStore.shared
    private var attachmentBarHeight: NSLayoutConstraint!
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let counter = UILabel()
    private let attachmentBar = UIStackView()
    private var attachments: [Attachment] = []
    /// Media ids already minted for an attachment, keyed by the attachment's
    /// local id — a Retry after a mid-batch failure skips completed uploads.
    private var uploadedIDs: [UUID: String] = [:]
    private var isPosting = false
    private var pendingLoads = 0
    private lazy var cancelButton = UIBarButtonItem(
        barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    private lazy var postButton = UIBarButtonItem(
        title: "Post", style: .prominent, target: self, action: #selector(post))
    private lazy var photoButton = UIBarButtonItem(
        image: DesignSystem.icon("photo.on.rectangle"),
        primaryAction: UIAction { [weak self] _ in self?.presentPicker() })

    private struct Attachment: Identifiable {
        let id = UUID()
        let media: ComposeMedia
        let thumbnail: UIImage

        init(_ loaded: ComposeMediaLoader.Loaded) {
            media = loaded.media
            thumbnail = loaded.thumbnail
        }
    }

    private static let maxAttachments = 4

    /// Whether the photo picker opens as soon as the screen is up.
    private var opensPhotoPicker: Bool

    init(mode: Mode, opensPhotoPicker: Bool = false) {
        self.mode = mode
        self.opensPhotoPicker = opensPhotoPicker
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.Color.background
        switch mode {
        case .new:
            title = "New Post"
            placeholder.text = "What’s happening?"
        case let .reply(tweet):
            title = "Reply to @\(tweet.author.handle)"
            placeholder.text = "Post your reply"
        case let .quote(tweet):
            title = "Quote @\(tweet.author.handle)"
            placeholder.text = "Add a comment"
        }
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItems = [postButton, photoButton]
        postButton.isEnabled = false

        textView.font = DesignSystem.Typography.editor()
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.textColor = DesignSystem.Color.label
        textView.accessibilityLabel = title
        textView.text = drafts.draft(for: ComposeDraftStore.slot(for: mode)) ?? ""

        placeholder.font = DesignSystem.Typography.editor()
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = DesignSystem.Color.tertiaryLabel
        placeholder.isAccessibilityElement = false

        counter.font = DesignSystem.Typography.metric()
        counter.textColor = DesignSystem.Color.secondaryLabel
        counter.accessibilityLabel = "Characters remaining"
        refreshState()

        attachmentBar.axis = .horizontal
        attachmentBar.spacing = DesignSystem.Spacing.s
        attachmentBar.alignment = .center
        attachmentBar.isHidden = true

        view.addManaged(textView)
        textView.addManaged(placeholder)
        view.addManaged(attachmentBar)
        view.addManaged(counter)

        let attachmentBarHeight = attachmentBar.heightAnchor.constraint(equalToConstant: 0)
        self.attachmentBarHeight = attachmentBarHeight
        layoutEditor()
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            attachmentBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            attachmentBar.bottomAnchor.constraint(equalTo: counter.topAnchor, constant: -DesignSystem.Spacing.s),
            attachmentBarHeight,
            counter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            counter.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -DesignSystem.Spacing.s),
        ])
    }

    /// Stacks the editor with the post it is about: a reply's post sits above
    /// the text, muted, so the user sees what they are answering; a quote's
    /// preview sits below it, as it will on X. A new post is just the text.
    private func layoutEditor() {
        let top = view.safeAreaLayoutGuide.topAnchor
        let gap = DesignSystem.Spacing.s
        switch mode {
        case .new:
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: top, constant: gap),
                textView.bottomAnchor.constraint(equalTo: attachmentBar.topAnchor, constant: -gap),
            ])
        case let .reply(tweet):
            let preview = QuotePreviewView(tweet: tweet, muted: true)
            view.addManaged(preview)
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: top, constant: gap),
                preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
                preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
                textView.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: gap),
                textView.bottomAnchor.constraint(equalTo: attachmentBar.topAnchor, constant: -gap),
            ])
        case let .quote(tweet):
            let preview = QuotePreviewView(tweet: tweet, muted: false)
            view.addManaged(preview)
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: top, constant: gap),
                preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
                preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
                preview.bottomAnchor.constraint(equalTo: attachmentBar.topAnchor, constant: -gap),
                textView.bottomAnchor.constraint(equalTo: preview.topAnchor, constant: -gap),
            ])
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
        if opensPhotoPicker {
            opensPhotoPicker = false
            presentPicker()
        } else {
            textView.becomeFirstResponder()
        }
    }

    // MARK: - Attachments

    private func presentPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selection = .ordered
        config.selectionLimit = max(1, Self.maxAttachments - attachments.count - pendingLoads)
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func addAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
        let thumb = AttachmentThumbnail(image: attachment.thumbnail) { [weak self] view in
            self?.removeAttachment(id: attachment.id, view: view)
        }
        attachmentBar.addArrangedSubview(thumb)
        syncAttachmentBar()
        updateControls()
    }

    private func removeAttachment(id: UUID, view: UIView) {
        attachments.removeAll { $0.id == id }
        view.removeFromSuperview()
        syncAttachmentBar()
        updateControls()
    }

    /// Shows the thumbnail row only while there are attachments, giving its
    /// height back to the text on a small screen with the keyboard up.
    private func syncAttachmentBar() {
        attachmentBar.isHidden = attachments.isEmpty
        attachmentBarHeight.constant = attachments.isEmpty ? 0 : 64
    }

    private func updateControls() {
        photoButton.isEnabled = !isPosting && attachments.count + pendingLoads < Self.maxAttachments
        refreshState()
    }

    /// Re-derives everything that follows from the draft, measuring it once:
    /// the counter (X's weighted 280 — URLs count 23, CJK and emoji 2 — so it
    /// agrees with what X will accept), the post gate, the placeholder, and
    /// whether swiping the sheet away needs a confirmation.
    private func refreshState() {
        let remaining = TweetCounter.remaining(for: textView.text)
        counter.text = "\(remaining)"
        counter.textColor = remaining < 0 ? .systemRed : DesignSystem.Color.secondaryLabel
        placeholder.isHidden = !textView.text.isEmpty
        postButton.isEnabled = !isPosting && pendingLoads == 0 && hasContent && remaining >= 0
        let guarded = hasContent || isPosting
        isModalInPresentation = guarded
        navigationController?.isModalInPresentation = guarded
    }

    private var hasContent: Bool {
        !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    @objc private func cancel() { requestDismiss() }

    enum Dismissal: Equatable {
        /// Leave the composer up.
        case stay
        /// Close it; there is nothing to lose.
        case close
        /// Ask whether to save, discard or keep editing the draft.
        case confirm
    }

    /// What a Cancel tap or a swipe down does.
    static func dismissal(hasContent: Bool, isPosting: Bool) -> Dismissal {
        if isPosting { return .stay }
        return hasContent ? .confirm : .close
    }

    /// Closes the composer, asking first when there is a draft to lose. Never
    /// while a post is on its way: the sheet stays so a failure can still
    /// offer Retry with the draft intact.
    private func requestDismiss() {
        switch Self.dismissal(hasContent: hasContent, isPosting: isPosting) {
        case .stay: return
        case .close: dismiss(animated: true); return
        case .confirm: break
        }
        let slot = ComposeDraftStore.slot(for: mode)
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let message = hasText && !attachments.isEmpty ? "Photos aren't kept with a saved draft." : nil
        let sheet = UIAlertController(title: nil, message: message, preferredStyle: .actionSheet)
        if hasText {
            sheet.addAction(UIAlertAction(title: "Save Draft", style: .default) { [weak self] _ in
                guard let self else { return }
                self.drafts.save(self.textView.text, for: slot)
                self.dismiss(animated: true)
            })
        }
        sheet.addAction(UIAlertAction(title: "Discard Draft", style: .destructive) { [weak self] _ in
            self?.drafts.clear(slot)
            self?.dismiss(animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = cancelButton
        present(sheet, animated: true)
    }

    // MARK: - Posting

    @objc private func post() {
        Task { await submit() }
    }

    /// Uploads pending attachments (sequentially, with per-item progress in
    /// the post button), then posts through the server API for the current
    /// mode. Success dismisses; failure re-enables the editor and offers Retry.
    private func submit() async {
        guard hasContent, !isPosting else { return }
        guard AppSettings.composeViaOfficialApp else {
            await postThroughServer()
            return
        }
        if attachments.isEmpty {
            handoffToOfficialApp()
        } else {
            confirmHandoffWithAttachments()
        }
    }

    /// The X app's compose link carries text only, so a draft with photos would
    /// lose them in the hand-off. Say so and let the user pick where to post.
    private func confirmHandoffWithAttachments() {
        let alert = UIAlertController(
            title: "The X app can't take photos",
            message: "Its compose link carries text only. Post from unrager to keep your photos, or open X without them.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Post from unrager", style: .default) { [weak self] _ in
            Task { await self?.postThroughServer() }
        })
        alert.addAction(UIAlertAction(title: "Open X without photos", style: .destructive) { [weak self] _ in
            self?.handoffToOfficialApp()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func postThroughServer() async {
        guard !isPosting else { return }
        isPosting = true
        setEditorLocked(true)
        defer {
            isPosting = false
            setEditorLocked(false)
        }
        do {
            let mediaIDs = try await uploadPendingAttachments()
            postButton.title = "Posting…"
            let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let result: ComposeResult
            var liked = false
            switch mode {
            case .new:
                result = try await EngageService.publish.compose(text: text, mediaIDs: mediaIDs)
            case let .reply(tweet):
                result = try await EngageService.publish.reply(to: tweet.restID, text: text, mediaIDs: mediaIDs)
                liked = await autoLikeIfReply()
            case let .quote(tweet):
                result = try await EngageService.publish.compose(
                    text: text, mediaIDs: mediaIDs, quoteTweetID: tweet.restID)
            }
            Haptics.success()
            drafts.clear(ComposeDraftStore.slot(for: mode))
            finish(Posted(id: result.id, likedReplyTarget: liked))
        } catch {
            Haptics.error()
            AppLogger.shared.warn("compose post failed: \(error)", category: .compose)
            presentPostFailure(error)
        }
    }

    /// Closes the composer and then tells the presenter, which confirms the
    /// post with a brief note unless it shows the result itself.
    private func finish(_ posted: Posted) {
        let onPosted = onPosted
        let presenter = presentingViewController
        let note: String
        switch mode {
        case .new, .quote: note = "Posted"
        case .reply: note = "Reply posted"
        }
        dismiss(animated: true) {
            if let onPosted {
                onPosted(posted)
            } else {
                presenter?.showToast(note)
            }
        }
    }

    /// Hands the draft to the official X app via an intent URL (falling back
    /// to the web composer), with the text also copied to the clipboard so
    /// anything the intent can't carry — media, or a quote when the app
    /// ignores the appended URL — can be pasted. No OAuth, no server post.
    private func handoffToOfficialApp() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = text
        var inReplyTo: String?
        switch mode {
        case .new:
            break
        case let .reply(tweet):
            inReplyTo = tweet.restID
        case let .quote(tweet):
            message = text.isEmpty ? tweet.url : "\(text) \(tweet.url)"
        }
        if !text.isEmpty { UIPasteboard.general.string = text }
        drafts.clear(ComposeDraftStore.slot(for: mode))

        var components = URLComponents(string: "https://x.com/intent/tweet")
        var items = [URLQueryItem(name: "text", value: message)]
        if let inReplyTo { items.append(URLQueryItem(name: "in_reply_to", value: inReplyTo)) }
        components?.queryItems = items
        guard let url = components?.url else { dismiss(animated: true); return }
        UIApplication.shared.open(url) { [weak self] _ in
            Haptics.success()
            self?.dismiss(animated: true)
        }
    }

    /// Uploads every attachment that hasn't already minted a media id and
    /// returns the ids in attachment order. Sequential, so the "Uploading
    /// N/M…" progress is honest and a failure pinpoints one item.
    private func uploadPendingAttachments() async throws -> [String] {
        var ids: [String] = []
        for (index, attachment) in attachments.enumerated() {
            if let existing = uploadedIDs[attachment.id] {
                ids.append(existing)
                continue
            }
            postButton.title = "Uploading \(index + 1)/\(attachments.count)…"
            let id = try await EngageService.publish.upload(attachment.media)
            uploadedIDs[attachment.id] = id
            ids.append(id)
        }
        return ids
    }

    /// Locks (or restores) the editor while a post is in flight so the draft
    /// can't mutate mid-upload; restoring re-derives the post button's
    /// enabled state from the draft.
    private func setEditorLocked(_ locked: Bool) {
        textView.isEditable = !locked
        attachmentBar.isUserInteractionEnabled = !locked
        cancelButton.isEnabled = !locked
        if !locked { postButton.title = "Post" }
        updateControls()
    }

    private func presentPostFailure(_ error: any Error) {
        let alert = UIAlertController(
            title: "Couldn't post",
            message: error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            Task { await self?.postThroughServer() }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Replying to someone auto-likes their post (mirroring the TUI's reply
    /// etiquette), only once the reply is posted. Best-effort and skipped when
    /// it's already liked; says whether a like went through.
    private func autoLikeIfReply() async -> Bool {
        guard case let .reply(tweet) = mode, !tweet.favorited else { return false }
        do {
            _ = try await AppEnvironment.shared.api.like(tweetID: tweet.restID)
            return true
        } catch {
            AppLogger.shared.warn("auto-like after reply failed: \(error)", category: .compose)
            return false
        }
    }

    /// ⌘↩ posts from a hardware keyboard, whenever the Post button would.
    override var keyCommands: [UIKeyCommand]? {
        let post = UIKeyCommand(title: "Post", action: #selector(postFromKeyboard), input: "\r", modifierFlags: .command)
        post.wantsPriorityOverSystemBehavior = true
        return [post]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(postFromKeyboard) { return postButton.isEnabled }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func postFromKeyboard() {
        guard postButton.isEnabled else { return }
        post()
    }
}

extension ComposeViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshState()
    }
}

extension ComposeViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        requestDismiss()
    }
}

extension ComposeViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        pendingLoads += results.count
        updateControls()
        let handoffs = results.map { ComposeMediaLoader.Handoff(provider: $0.itemProvider) }
        Task {
            var loaded: [ComposeMediaLoader.Loaded?] = Array(repeating: nil, count: handoffs.count)
            await withTaskGroup(of: (Int, ComposeMediaLoader.Loaded?).self) { group in
                for (index, handoff) in handoffs.enumerated() {
                    group.addTask { (index, try? await ComposeMediaLoader.load(handoff)) }
                }
                for await (index, item) in group { loaded[index] = item }
            }
            pendingLoads -= handoffs.count
            for item in loaded {
                if let item, attachments.count < Self.maxAttachments { addAttachment(Attachment(item)) }
            }
            updateControls()
            let failed = loaded.filter { $0 == nil }.count
            if failed > 0 { presentPickFailure(count: failed) }
        }
    }

    private func presentPickFailure(count: Int) {
        let alert = UIAlertController(
            title: count == 1 ? "A photo couldn't be added" : "\(count) photos couldn't be added",
            message: "They could not be read from your library. Try picking them again.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// The quoted tweet's preview card in the quote composer: author line + a few
/// lines of text in the same bordered treatment as `TweetCell`'s inline quote.
private final class QuotePreviewView: UIView {
    /// `muted` dims the card for the post a reply answers, which is context
    /// rather than part of what gets posted.
    init(tweet: Tweet, muted: Bool) {
        super.init(frame: .zero)
        layer.cornerRadius = DesignSystem.Radius.control
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DesignSystem.Color.separator.cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: QuotePreviewView, _) in
            view.layer.borderColor = DesignSystem.Color.separator.cgColor
        }

        let author = UILabel()
        author.numberOfLines = 1
        let attributed = NSMutableAttributedString(string: tweet.author.name, attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: DesignSystem.Color.label,
        ])
        attributed.append(NSAttributedString(string: " @\(tweet.author.handle)", attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: DesignSystem.handleColor(tweet.author.handle),
        ]))
        author.attributedText = attributed

        let text = ReplyContext.body(of: tweet)
        let body = UILabel()
        body.font = DesignSystem.Typography.metric()
        body.textColor = muted ? DesignSystem.Color.secondaryLabel : DesignSystem.Color.label
        body.numberOfLines = muted ? 3 : 4
        body.text = text
        body.isHidden = text.isEmpty
        if muted { author.alpha = 0.7 }

        let stack = UIStackView(arrangedSubviews: [author, body])
        stack.axis = .vertical
        stack.spacing = 6
        addManaged(stack)
        stack.pinEdges(to: self, insets: UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))

        isAccessibilityElement = true
        accessibilityLabel = "\(muted ? "Replying to" : "Quoting") \(tweet.author.name): \(text)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

}

/// A removable square preview of a pending attachment, with a corner close
/// button.
private final class AttachmentThumbnail: UIView {
    private let onRemove: (UIView) -> Void

    init(image: UIImage, onRemove: @escaping (UIView) -> Void) {
        self.onRemove = onRemove
        super.init(frame: .zero)
        let imageView = UIImageView(image: image)
        imageView.accessibilityIgnoresInvertColors = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = DesignSystem.Radius.control
        imageView.layer.cornerCurve = .continuous
        addManaged(imageView)
        imageView.pinEdges(to: self)

        let remove = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(
            paletteColors: [.white, UIColor.black.withAlphaComponent(0.6)]))?
            .applyingSymbolConfiguration(.init(pointSize: 20))
        config.contentInsets = .init(top: 3, leading: 3, bottom: 3, trailing: 3)
        remove.configuration = config
        remove.contentHorizontalAlignment = .trailing
        remove.contentVerticalAlignment = .top
        remove.addAction(UIAction { [weak self] _ in guard let self else { return }; self.onRemove(self) }, for: .touchUpInside)
        remove.accessibilityLabel = "Remove attachment"
        addManaged(remove)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 64),
            remove.topAnchor.constraint(equalTo: topAnchor),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.widthAnchor.constraint(equalToConstant: 44),
            remove.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
