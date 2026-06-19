import PhotosUI
import UIKit
import UnragerKit

/// Compose a new tweet or a reply. unrager never posts to X itself: the action
/// copies the composed text to the clipboard and opens X's web compose intent
/// (prefilled, and for replies anchored to the parent tweet), then dismisses —
/// mirroring the TUI's open-X behavior. The in-app editor (text + char count,
/// photo thumbnails) stays for drafting; the button reads "Open in X".
final class ComposeViewController: UIViewController {
    enum Mode {
        case new
        case reply(to: Tweet)
    }

    private let mode: Mode
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let counter = UILabel()
    private let attachmentBar = UIStackView()
    private var attachments: [Attachment] = []
    private lazy var postButton = UIBarButtonItem(
        title: "Open in X", style: .prominent, target: self, action: #selector(post))
    private lazy var photoButton = UIBarButtonItem(
        image: DesignSystem.icon("photo.on.rectangle"),
        primaryAction: UIAction { [weak self] _ in self?.presentPicker() })

    private struct Attachment: Identifiable {
        let id = UUID()
        let media: ComposeMedia
        let thumbnail: UIImage
    }

    private static let maxAttachments = 4

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.Color.background
        switch mode {
        case .new: title = "New Tweet"
        case let .reply(tweet): title = "Reply to @\(tweet.author.handle)"
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItems = [postButton, photoButton]
        postButton.isEnabled = false

        textView.font = DesignSystem.Typography.system(20, weight: .regular)
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.textColor = DesignSystem.Color.label

        placeholder.text = "What’s happening?"
        placeholder.font = DesignSystem.Typography.system(20, weight: .regular)
        placeholder.textColor = DesignSystem.Color.tertiaryLabel

        counter.font = DesignSystem.Typography.metric()
        counter.textColor = DesignSystem.Color.secondaryLabel
        updateCounter()

        attachmentBar.axis = .horizontal
        attachmentBar.spacing = DesignSystem.Spacing.s
        attachmentBar.alignment = .center
        attachmentBar.isHidden = true

        view.addManaged(textView)
        textView.addManaged(placeholder)
        view.addManaged(attachmentBar)
        view.addManaged(counter)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: DesignSystem.Spacing.s),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            textView.bottomAnchor.constraint(equalTo: attachmentBar.topAnchor, constant: -DesignSystem.Spacing.s),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            attachmentBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            attachmentBar.bottomAnchor.constraint(equalTo: counter.topAnchor, constant: -DesignSystem.Spacing.s),
            attachmentBar.heightAnchor.constraint(equalToConstant: 64),
            counter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            counter.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -DesignSystem.Spacing.s),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    // MARK: - Attachments

    private func presentPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = Self.maxAttachments - attachments.count
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
        attachmentBar.isHidden = attachments.isEmpty
        updateControls()
    }

    private func removeAttachment(id: UUID, view: UIView) {
        attachments.removeAll { $0.id == id }
        view.removeFromSuperview()
        attachmentBar.isHidden = attachments.isEmpty
        updateControls()
    }

    private func updateControls() {
        photoButton.isEnabled = attachments.count < Self.maxAttachments
        textViewDidChange(textView)
    }

    private func updateCounter() {
        let remaining = 280 - textView.text.count
        counter.text = "\(remaining)"
        counter.textColor = remaining < 0 ? .systemRed : DesignSystem.Color.secondaryLabel
    }

    private var hasContent: Bool {
        !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    @objc private func cancel() { dismiss(animated: true) }

    /// Copies the draft to the clipboard (a backup, since intent URLs can drop
    /// long text) and opens X's compose intent prefilled. For replies the parent
    /// id is appended so X anchors the reply. Then dismisses.
    @objc private func post() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasContent else { return }
        UIPasteboard.general.string = text
        Haptics.success()
        autoLikeIfReply()
        openInX(text: text)
        dismiss(animated: true)
    }

    /// Replying to someone auto-likes their tweet (mirroring the TUI's reply
    /// etiquette). Best-effort and skipped when it's already liked.
    private func autoLikeIfReply() {
        guard case let .reply(tweet) = mode, !tweet.favorited else { return }
        Task { _ = try? await AppEnvironment.shared.api.like(tweetID: tweet.restID) }
    }

    /// Hands the draft off to the real X app. A reply opens the parent tweet
    /// in-app so the reply lands in the right thread (matching the TUI — the X
    /// URL scheme can't prefill a reply composer); a new tweet opens the
    /// composer prefilled. The web URL is the fallback when the app is absent.
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
            webURL = intentURL(text: text)
        }
        if let appURL, UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
            return
        }
        if let webURL { UIApplication.shared.open(webURL) }
    }

    private func intentURL(text: String) -> URL? {
        var components = URLComponents(string: "https://x.com/intent/post")
        var items = [URLQueryItem(name: "text", value: text)]
        if case let .reply(tweet) = mode {
            items.append(URLQueryItem(name: "in_reply_to", value: tweet.restID))
        }
        components?.queryItems = items
        return components?.url
    }
}

extension ComposeViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        postButton.isEnabled = hasContent && textView.text.count <= 280
        updateCounter()
    }
}

extension ComposeViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let image = object as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.85) else { return }
                let attachment = Attachment(
                    media: ComposeMedia(data: data, filename: "\(UUID().uuidString).jpg", mimeType: "image/jpeg"),
                    thumbnail: image)
                Task { @MainActor in self?.addAttachment(attachment) }
            }
        }
    }
}

/// A removable square preview of a pending attachment, with a corner close
/// button.
private final class AttachmentThumbnail: UIView {
    private let onRemove: (UIView) -> Void

    init(image: UIImage, onRemove: @escaping (UIView) -> Void) {
        self.onRemove = onRemove
        super.init(frame: .zero)
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = DesignSystem.Radius.control
        imageView.layer.cornerCurve = .continuous
        addManaged(imageView)
        imageView.pinEdges(to: self)

        let remove = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.image = DesignSystem.icon("xmark", pointSize: 11, weight: .bold)
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.6)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = .init(top: 3, leading: 3, bottom: 3, trailing: 3)
        remove.configuration = config
        remove.addAction(UIAction { [weak self] _ in guard let self else { return }; self.onRemove(self) }, for: .touchUpInside)
        remove.accessibilityLabel = "Remove attachment"
        addManaged(remove)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 64),
            remove.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
