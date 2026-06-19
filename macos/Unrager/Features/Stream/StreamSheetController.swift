import AppKit
import UnragerKit

/// A sheet that consumes an LLM token stream (ask / brief / translate),
/// accumulating tokens into a buffer rendered as lightweight markdown. Mirrors
/// the iOS `StreamSheetViewController`.
@MainActor
final class StreamSheetController: NSViewController {
    private let titleText: String
    private let makeStream: () -> AsyncThrowingStream<TokenEvent, any Error>

    private let spinner = NSProgressIndicator()
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var raw = ""
    private var task: Task<Void, Never>?

    init(title: String, makeStream: @escaping () -> AsyncThrowingStream<TokenEvent, any Error>) {
        self.titleText = title
        self.makeStream = makeStream
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { task?.cancel() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 460))
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true

        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = DesignSystem.Typography.title()
        titleLabel.textColor = DesignSystem.Color.label

        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: DesignSystem.Spacing.l, height: DesignSystem.Spacing.m)
        textView.font = DesignSystem.Typography.body()
        textView.textColor = DesignSystem.Color.label
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let header = NSStackView(views: [titleLabel, NSView(), spinner, doneButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = DesignSystem.Spacing.s

        view.addManaged(header)
        view.addManaged(scrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.l),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.l),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: DesignSystem.Spacing.l),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignSystem.Spacing.s),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -DesignSystem.Spacing.l),
        ])

        start()
    }

    private func start() {
        let stream = makeStream()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    if Task.isCancelled { return }
                    if !event.token.isEmpty {
                        self.spinner.stopAnimation(nil)
                        self.raw.append(event.token)
                        self.render()
                    }
                    if event.done { break }
                }
                self.spinner.stopAnimation(nil)
                if self.raw.isEmpty { self.setPlain("(no response)", color: DesignSystem.Color.secondaryLabel) }
            } catch {
                self.spinner.stopAnimation(nil)
                self.setPlain(error.localizedDescription, color: .systemRed)
            }
        }
    }

    private func render() {
        textView.textStorage?.setAttributedString(Self.markdown(raw))
        textView.scrollToEndOfDocument(nil)
    }

    private func setPlain(_ text: String, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DesignSystem.Typography.body(),
            .foregroundColor: color,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Lightweight markdown: bullets for `* ` / `- ` lines, inline emphasis via
    /// `AttributedString`'s inline parser, preserving newlines.
    static func markdown(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: DesignSystem.Typography.body(),
            .foregroundColor: DesignSystem.Color.label,
        ]
        let lines = source.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            var line = rawLine
            if line.hasPrefix("* ") || line.hasPrefix("- ") {
                line = "•  " + line.dropFirst(2)
            }
            let options = AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let attributed: NSAttributedString
            if let parsed = try? AttributedString(markdown: line, options: options) {
                attributed = NSAttributedString(parsed)
            } else {
                attributed = NSAttributedString(string: line)
            }
            let mutable = NSMutableAttributedString(attributedString: attributed)
            let full = NSRange(location: 0, length: mutable.length)
            mutable.addAttribute(.foregroundColor, value: DesignSystem.Color.label, range: full)
            mutable.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
                let resolved = (value as? NSFont).map { Self.scale($0) } ?? DesignSystem.Typography.body()
                mutable.addAttribute(.font, value: resolved, range: range)
            }
            result.append(mutable)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        return result
    }

    /// Maps a markdown-produced font onto the body size while keeping bold /
    /// italic traits.
    private static func scale(_ font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        let size = DesignSystem.Typography.body().pointSize
        var weight: NSFont.Weight = .regular
        if traits.contains(.bold) { weight = .bold }
        var resolved = NSFont.systemFont(ofSize: size, weight: weight)
        if traits.contains(.italic),
           let italic = NSFontManager.shared.convert(resolved, toHaveTrait: .italicFontMask) as NSFont? {
            resolved = italic
        }
        return resolved
    }

    @objc private func done() {
        task?.cancel()
        if let sheetParent = presentingViewController {
            sheetParent.dismiss(self)
        } else {
            view.window?.sheetParent?.endSheet(view.window!)
        }
    }
}
