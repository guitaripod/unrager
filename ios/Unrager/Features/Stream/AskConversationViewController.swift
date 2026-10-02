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
    /// The confirmed question/answer turns — exactly what the model is sent as
    /// history, so an error or an unfinished answer never becomes part of it.
    private var turns: [AskTurn] = []
    private var pendingPrompt: String?
    private var streamingAnswer: String?
    private var failure: String?
    private var streamTask: Task<Void, Never>?
    private var renderedTurns: [Int: NSAttributedString] = [:]
    private var follower: StreamingTextFollower!

    private let textView = UITextView()
    private let inputBar = UIView()
    private let inputField = UITextField()
    private let sendButton = UIButton(configuration: .prominentGlass())
    private let retryButton = UIButton(configuration: .tinted())

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
        follower = StreamingTextFollower(textView: textView) { [weak self] in
            self?.transcript() ?? NSAttributedString()
        }
        view.addManaged(textView)

        configureInputBar()

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
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

        sendButton.addAction(UIAction { [weak self] _ in self?.sendOrStop() }, for: .touchUpInside)
        applySendButtonState(streaming: false)

        var retry = UIButton.Configuration.tinted()
        retry.title = "Retry"
        retry.image = DesignSystem.icon("arrow.clockwise", pointSize: 13)
        retry.imagePadding = 6
        retry.cornerStyle = .capsule
        retryButton.configuration = retry
        retryButton.isHidden = true
        retryButton.addAction(UIAction { [weak self] _ in self?.retryFailed() }, for: .touchUpInside)
        view.addManaged(retryButton)

        inputBar.addManaged(inputField)
        inputBar.addManaged(sendButton)
        let separator = HairlineView()
        inputBar.addManaged(separator)

        NSLayoutConstraint.activate([
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            separator.topAnchor.constraint(equalTo: inputBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor),

            inputField.topAnchor.constraint(equalTo: inputBar.topAnchor, constant: DesignSystem.Spacing.s),
            inputField.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -DesignSystem.Spacing.s),
            inputField.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor, constant: DesignSystem.Spacing.l),
            inputField.heightAnchor.constraint(equalToConstant: 36),

            sendButton.leadingAnchor.constraint(equalTo: inputField.trailingAnchor, constant: DesignSystem.Spacing.s),
            sendButton.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor, constant: -DesignSystem.Spacing.l),
            sendButton.centerYAnchor.constraint(equalTo: inputField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),

            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -DesignSystem.Spacing.m),
        ])
    }

    /// The send button sends a follow-up when idle and stops the answer while
    /// one is streaming.
    private func applySendButtonState(streaming: Bool) {
        var config = UIButton.Configuration.prominentGlass()
        config.image = DesignSystem.icon(streaming ? "stop.fill" : "arrow.up", pointSize: 15, weight: .bold)
        sendButton.configuration = config
        sendButton.accessibilityLabel = streaming ? "Stop answering" : "Send follow-up"
    }

    private func sendOrStop() {
        if streamTask != nil {
            stopStreaming()
        } else {
            sendFromField()
        }
    }

    /// Ends the answer in progress at the user's request: what has streamed so
    /// far is kept as the answer, and a question stopped before any text can be
    /// retried.
    private func stopStreaming() {
        streamTask?.cancel()
        let answer = streamingAnswer ?? ""
        if answer.isEmpty {
            finishStream(error: AskStopped())
        } else {
            finishStream(error: nil)
        }
    }

    private func retryFailed() {
        guard let prompt = pendingPrompt, streamTask == nil else { return }
        send(prompt: prompt)
    }

    private struct AskStopped: LocalizedError {
        var errorDescription: String? { "Stopped before an answer arrived." }
    }

    private func sendFromField() {
        let prompt = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, streamTask == nil else { return }
        if pendingPrompt != nil { pendingPrompt = nil; failure = nil }
        inputField.text = nil
        send(prompt: prompt)
    }

    /// Fires the stream with the confirmed history plus this question and the
    /// thread context, and folds the streamed tokens into the transcript live.
    private func send(prompt: String) {
        pendingPrompt = prompt
        failure = nil
        streamingAnswer = ""
        follower.resumeFollowing()
        retryButton.isHidden = true
        setStreaming(true)
        render()
        UIAccessibility.post(notification: .announcement, argument: "Asking")

        let request = AskRequest(
            tweetID: context.tweet.restID,
            turns: turns + [AskTurn(role: .user, text: prompt)],
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
                        self.follower.scheduleRender()
                    }
                    if event.done { break }
                }
                guard !Task.isCancelled else { return }
                self.finishStream(error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.finishStream(error: error)
            }
        }
    }

    /// Settles the answer in flight. A complete answer joins the history; an
    /// error or an empty reply never does, and leaves the question on screen
    /// with a Retry, so the next follow-up isn't answered on top of a failure.
    private func finishStream(error: (any Error)?) {
        let answer = streamingAnswer ?? ""
        streamingAnswer = nil
        streamTask = nil
        setStreaming(false)
        if let error {
            AppLogger.shared.warn("ask stream failed: \(error)", category: .thread)
            failure = error.localizedDescription
            retryButton.isHidden = false
            Haptics.error()
        } else if answer.isEmpty {
            failure = "The model returned no answer."
            retryButton.isHidden = false
            Haptics.error()
        } else if let prompt = pendingPrompt {
            turns.append(AskTurn(role: .user, text: prompt))
            turns.append(AskTurn(role: .assistant, text: answer))
            pendingPrompt = nil
            UIAccessibility.post(notification: .announcement, argument: "Answer ready")
        }
        render()
    }

    private func setStreaming(_ streaming: Bool) {
        applySendButtonState(streaming: streaming)
    }

    private func render() {
        follower.renderNow()
    }

    /// Rebuilds the transcript: each user question as a bold accent line, each
    /// answer rendered as markdown (finished answers are rendered once and
    /// kept); the in-flight answer streams at the bottom, followed by any
    /// failure.
    private func transcript() -> NSAttributedString {
        let transcript = NSMutableAttributedString()
        func separate() { if transcript.length > 0 { transcript.append(NSAttributedString(string: "\n\n")) } }
        for (index, turn) in turns.enumerated() {
            separate()
            transcript.append(renderedTurn(turn, at: index))
        }
        if let pendingPrompt {
            separate()
            transcript.append(Self.questionText(pendingPrompt))
        }
        if let streamingAnswer {
            separate()
            transcript.append(streamingAnswer.isEmpty ? Self.placeholderText : StreamSheetViewController.renderMarkdown(streamingAnswer))
        }
        if let failure {
            separate()
            transcript.append(NSAttributedString(string: failure, attributes: [
                .font: DesignSystem.Typography.body(), .foregroundColor: UIColor.systemRed]))
        }
        return transcript
    }

    private func renderedTurn(_ turn: AskTurn, at index: Int) -> NSAttributedString {
        if let cached = renderedTurns[index] { return cached }
        let rendered: NSAttributedString
        switch turn.role {
        case .user: rendered = Self.questionText(turn.text)
        case .assistant: rendered = StreamSheetViewController.renderMarkdown(turn.text)
        }
        renderedTurns[index] = rendered
        return rendered
    }

    private static func questionText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: DesignSystem.Typography.body().withWeight(.semibold),
            .foregroundColor: DesignSystem.Color.accent])
    }

    private static var placeholderText: NSAttributedString {
        NSAttributedString(string: "…", attributes: [
            .font: DesignSystem.Typography.body(), .foregroundColor: DesignSystem.Color.secondaryLabel])
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
