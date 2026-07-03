import UIKit
import UnragerKit

/// The conversational Ask sheet: streams an answer about a tweet with the
/// thread as context (mirroring the TUI's ask view), then keeps the
/// conversation going — a follow-up input at the bottom appends further
/// question/answer turns, all sent through `POST /api/sse/ask` with the prior
/// turns so the model keeps context.
final class AskConversationViewController: UIViewController {
    /// The tweet being asked about plus whatever thread context the caller has
    /// loaded — ancestors root-first, same-level siblings, direct replies.
    struct Context {
        let tweet: Tweet
        var ancestors: [Tweet] = []
        var siblings: [Tweet] = []
        var replies: [Tweet] = []
    }

    /// The TUI's ask presets (`src/tui/ask.rs::PRESETS`), verbatim.
    struct Preset {
        let label: String
        let prompt: String
        let needsReplies: Bool
    }

    static let allPresets: [Preset] = [
        Preset(label: "Explain", prompt: "Explain this post.", needsReplies: false),
        Preset(label: "Replies",
               prompt: "Summarize the key points of the replies in 3–5 bullets. Focus on dominant reactions and any notable disagreements.",
               needsReplies: true),
        Preset(label: "Counter",
               prompt: "What are the strongest counter-arguments to this post? List 2–3, each one or two sentences.",
               needsReplies: false),
        Preset(label: "ELI5", prompt: "Explain this post like I'm five.", needsReplies: false),
        Preset(label: "Entities",
               prompt: "Who and what is referenced in this post? Identify people, projects, events, or topics mentioned.",
               needsReplies: false),
    ]

    /// The presets available for a tweet — the replies summary only makes
    /// sense when replies are loaded, matching the TUI's gating.
    static func presets(hasReplies: Bool) -> [Preset] {
        allPresets.filter { hasReplies || !$0.needsReplies }
    }

    private let context: Context
    private let initialPrompt: String
    private let askAPI = AskAPI(baseURL: { AppSettings.serverURL })
    private var turns: [AskTurn] = []
    private var streamingAnswer: String?
    private var streamTask: Task<Void, Never>?

    private let textView = UITextView()
    private let inputBar = UIView()
    private let inputField = UITextField()
    private let sendButton = UIButton(configuration: .prominentGlass())
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(context: Context, initialPrompt: String) {
        self.context = context
        self.initialPrompt = initialPrompt
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Ask · @\(context.tweet.author.handle)"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        textView.font = DesignSystem.Typography.body()
        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.textColor = DesignSystem.Color.label
        textView.textContainerInset = .init(top: 16, left: 16, bottom: 16, right: 16)
        textView.alwaysBounceVertical = true
        view.addManaged(textView)

        configureInputBar()

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
        ])

        spinner.hidesWhenStopped = true
        view.addManaged(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])

        send(prompt: initialPrompt)
    }

    /// The follow-up bar: a rounded text field plus a send button, pinned above
    /// the keyboard via the keyboard layout guide so it rides up with it.
    private func configureInputBar() {
        inputBar.backgroundColor = DesignSystem.Color.background
        view.addManaged(inputBar)

        inputField.placeholder = "Ask a follow-up…"
        inputField.font = DesignSystem.Typography.body()
        inputField.borderStyle = .none
        inputField.backgroundColor = DesignSystem.Color.elevatedBackground
        inputField.layer.cornerRadius = 18
        inputField.layer.cornerCurve = .continuous
        inputField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        inputField.leftViewMode = .always
        inputField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        inputField.rightViewMode = .always
        inputField.returnKeyType = .send
        inputField.autocorrectionType = .default
        inputField.delegate = self
        inputField.accessibilityLabel = "Follow-up question"

        var config = UIButton.Configuration.prominentGlass()
        config.image = DesignSystem.icon("arrow.up", pointSize: 15, weight: .bold)
        sendButton.configuration = config
        sendButton.accessibilityLabel = "Send follow-up"
        sendButton.addAction(UIAction { [weak self] _ in self?.sendFromField() }, for: .touchUpInside)

        inputBar.addManaged(inputField)
        inputBar.addManaged(sendButton)
        let separator = UIView()
        separator.backgroundColor = DesignSystem.Color.separator
        inputBar.addManaged(separator)

        NSLayoutConstraint.activate([
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            separator.topAnchor.constraint(equalTo: inputBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / max(1, UITraitCollection.current.displayScale)),

            inputField.topAnchor.constraint(equalTo: inputBar.topAnchor, constant: DesignSystem.Spacing.s),
            inputField.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -DesignSystem.Spacing.s),
            inputField.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor, constant: DesignSystem.Spacing.l),
            inputField.heightAnchor.constraint(equalToConstant: 36),

            sendButton.leadingAnchor.constraint(equalTo: inputField.trailingAnchor, constant: DesignSystem.Spacing.s),
            sendButton.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor, constant: -DesignSystem.Spacing.l),
            sendButton.centerYAnchor.constraint(equalTo: inputField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func sendFromField() {
        let prompt = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, streamTask == nil else { return }
        inputField.text = nil
        send(prompt: prompt)
    }

    /// Appends the user turn, fires the stream with the full history + thread
    /// context, and folds the streamed tokens into the transcript live.
    private func send(prompt: String) {
        turns.append(AskTurn(role: .user, text: prompt))
        streamingAnswer = ""
        setStreaming(true)
        render()

        let request = AskRequest(
            tweetID: context.tweet.restID,
            turns: turns,
            ancestors: context.ancestors.map(AskContextEntry.init(tweet:)),
            siblings: context.siblings.map(AskContextEntry.init(tweet:)),
            replies: context.replies.map(AskContextEntry.init(tweet:)))

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.askAPI.askStream(request) {
                    guard !Task.isCancelled else { return }
                    if !event.token.isEmpty {
                        self.streamingAnswer = (self.streamingAnswer ?? "") + event.token
                        self.render()
                    }
                    if event.done { break }
                }
                self.finishStream(error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.finishStream(error: error)
            }
        }
    }

    private func finishStream(error: (any Error)?) {
        let answer = streamingAnswer ?? ""
        streamingAnswer = nil
        streamTask = nil
        setStreaming(false)
        if let error {
            AppLogger.shared.warn("ask stream failed: \(error)", category: .thread)
            turns.append(AskTurn(role: .assistant,
                                 text: answer.isEmpty ? "_\(error.localizedDescription)_" : answer))
            Haptics.error()
        } else {
            turns.append(AskTurn(role: .assistant, text: answer.isEmpty ? "_(no response)_" : answer))
        }
        render()
    }

    private func setStreaming(_ streaming: Bool) {
        sendButton.isEnabled = !streaming
        if streaming, turns.count <= 1 { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    /// Rebuilds the transcript: each user question as a bold accent line, each
    /// answer rendered as markdown; the in-flight answer streams at the bottom.
    private func render() {
        spinnerStopIfContent()
        let transcript = NSMutableAttributedString()
        var entries: [AskTurn] = turns
        if let streamingAnswer {
            entries.append(AskTurn(role: .assistant, text: streamingAnswer))
        }
        for (index, turn) in entries.enumerated() {
            if index > 0 { transcript.append(NSAttributedString(string: "\n\n")) }
            switch turn.role {
            case .user:
                transcript.append(NSAttributedString(
                    string: turn.text,
                    attributes: [.font: DesignSystem.Typography.body().withWeight(.semibold),
                                 .foregroundColor: DesignSystem.Color.accent]))
            case .assistant:
                if turn.text.isEmpty {
                    transcript.append(NSAttributedString(
                        string: "…",
                        attributes: [.font: DesignSystem.Typography.body(),
                                     .foregroundColor: DesignSystem.Color.secondaryLabel]))
                } else {
                    transcript.append(StreamSheetViewController.renderMarkdown(turn.text))
                }
            }
        }
        textView.attributedText = transcript
        scrollToBottom()
    }

    private func spinnerStopIfContent() {
        if streamingAnswer?.isEmpty == false { spinner.stopAnimating() }
    }

    private func scrollToBottom() {
        let length = textView.attributedText?.length ?? 0
        guard length > 0 else { return }
        textView.scrollRangeToVisible(NSRange(location: length - 1, length: 1))
    }

    /// Stops generation the moment the sheet goes away, matching the plain
    /// stream sheet's teardown contract.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || isMovingFromParent
            || navigationController?.isBeingDismissed == true else { return }
        streamTask?.cancel()
        streamTask = nil
    }

    deinit { streamTask?.cancel() }
}

extension AskConversationViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendFromField()
        return false
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
