import UIKit
import UnragerKit

/// Presents a streamed LLM response (ask / brief / translate). Tokens append
/// live; cancelling dismisses and tears down the stream.
final class StreamSheetViewController: UIViewController {
    private let streamTitle: String
    private let makeStream: @Sendable () -> AsyncThrowingStream<TokenEvent, Error>
    private let textView = UITextView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var task: Task<Void, Never>?
    private var raw = ""
    private var failure: String?
    private var finished = false
    private var follower: StreamingTextFollower!

    init(title: String, stream: @escaping @Sendable () -> AsyncThrowingStream<TokenEvent, Error>) {
        self.streamTitle = title
        self.makeStream = stream
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = streamTitle
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        textView.font = DesignSystem.Typography.body()
        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.textColor = DesignSystem.Color.label
        textView.textContainerInset = .init(top: 16, left: 16, bottom: 16, right: 16)
        view.addManaged(textView)
        follower = StreamingTextFollower(textView: textView) { [weak self] in
            self?.shownText() ?? NSAttributedString()
        }
        textView.pinEdges(toSafeAreaOf: view)

        spinner.startAnimating()
        view.addManaged(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
        start()
    }

    /// The stream task captures `self` weakly: a strong capture would keep the
    /// sheet (and the live SSE connection, and the server's Ollama generation)
    /// alive until the stream ran to completion, making the deinit cancel
    /// unreachable mid-stream.
    private func start() {
        follower.resumeFollowing()
        let stream = makeStream()
        task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    if !event.token.isEmpty {
                        self.spinner.stopAnimating()
                        self.raw.append(event.token)
                        self.follower.scheduleRender()
                    }
                    if event.done { break }
                }
                guard let self, !Task.isCancelled else { return }
                self.finish()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.showFailure(error)
            }
        }
    }

    private func finish() {
        spinner.stopAnimating()
        finished = true
        follower.renderNow()
        guard !raw.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: "Answer ready")
    }

    /// The answer so far, then what went wrong when the stream failed, or a
    /// note when it ended without a word.
    private func shownText() -> NSAttributedString {
        let shown = NSMutableAttributedString(attributedString: raw.isEmpty ? NSAttributedString() : Self.renderMarkdown(raw))
        if let failure {
            if shown.length > 0 { shown.append(NSAttributedString(string: "\n\n")) }
            shown.append(NSAttributedString(string: failure, attributes: [
                .font: DesignSystem.Typography.body(), .foregroundColor: UIColor.systemRed]))
        } else if finished, raw.isEmpty {
            shown.append(NSAttributedString(string: "(no response)", attributes: [
                .font: DesignSystem.Typography.body(), .foregroundColor: DesignSystem.Color.secondaryLabel]))
        }
        return shown
    }

    /// Keeps whatever streamed before the failure and says what went wrong
    /// under it, with a Retry in the bar that starts the request over.
    private func showFailure(_ error: any Error) {
        spinner.stopAnimating()
        failure = error.localizedDescription
        follower.renderNow()
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: DesignSystem.icon("arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.retry() })
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Retry"
    }

    private func retry() {
        navigationItem.leftBarButtonItem = nil
        raw = ""
        failure = nil
        finished = false
        follower.renderNow()
        spinner.startAnimating()
        start()
    }

    /// Tears the stream down the moment the sheet goes away (Done, swipe-down,
    /// or a pop) so the server stops generating immediately instead of when
    /// deinit eventually runs.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || isMovingFromParent
            || navigationController?.isBeingDismissed == true else { return }
        task?.cancel()
        task = nil
    }

    /// Renders the LLM's markdown (bold + bullets) while preserving newlines.
    /// Shared with the conversational ask sheet so both render identically.
    static func renderMarkdown(_ markdown: String) -> NSAttributedString {
        let bulletized = markdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop { $0 == " " }
                if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") {
                    return "•  " + trimmed.dropFirst(2)
                }
                return String(line)
            }
            .joined(separator: "\n")

        return InlineMarkdown.render(bulletized, font: DesignSystem.Typography.body(), color: DesignSystem.Color.label)
    }

    deinit { task?.cancel() }
}

extension UIViewController {
    /// Presents a streaming sheet wrapped in its own navigation controller.
    func presentStream(title: String, stream: @escaping @Sendable () -> AsyncThrowingStream<TokenEvent, Error>) {
        let sheet = StreamSheetViewController(title: title, stream: stream)
        let nav = UINavigationController(rootViewController: sheet)
        if let presentation = nav.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
}
