import UIKit
import UnragerKit

/// "What's new": renders the bundled `CHANGELOG.md` as formatted, read-only
/// text — version headings, bulleted entries with inline bold — entirely
/// offline (the file ships in the app bundle). The newest versions render off
/// the main thread so the screen slides in at once; the rest wait behind a
/// "Show older versions" button and arrive a version at a time.
final class ChangelogViewController: UIViewController {
    /// How many versions with entries show before "Show older versions".
    nonisolated static let recentVersionCount = 2

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let olderButton = UIButton(configuration: .gray())
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private var olderVersions: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "What's new"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never

        scrollView.alwaysBounceVertical = true
        view.addManaged(scrollView)
        scrollView.pinEdges(toSafeAreaOf: view)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 32, trailing: 16)
        scrollView.addManaged(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])

        olderButton.configuration?.title = "Show older versions"
        olderButton.configuration?.cornerStyle = .capsule
        olderButton.isHidden = true
        olderButton.addAction(UIAction { [weak self] _ in self?.showOlder() }, for: .primaryActionTriggered)
        stack.addArrangedSubview(olderButton)

        loadingIndicator.hidesWhenStopped = true
        view.addManaged(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        loadingIndicator.startAnimating()
        Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { () -> Rendered in
                let parts = Self.split(markdown: Self.bundledChangelog(), recent: Self.recentVersionCount)
                return Rendered(texts: [Self.render(markdown: parts.recent)], older: parts.older)
            }.value
            guard let self else { return }
            self.loadingIndicator.stopAnimating()
            self.olderVersions = rendered.older
            self.append(rendered.texts[0])
            self.olderButton.isHidden = rendered.older.isEmpty
        }
    }

    /// Text rendered off the main thread. The attributed strings are built
    /// there and never mutated afterwards, so handing them over is safe.
    private struct Rendered: @unchecked Sendable {
        let texts: [NSAttributedString]
        let older: [String]
    }

    /// Adds a block of text above the button, as its own non-scrolling text
    /// view so each block lays out on its own.
    private func append(_ text: NSAttributedString) {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.attributedText = text
        stack.insertArrangedSubview(textView, at: stack.arrangedSubviews.count - 1)
        stack.setCustomSpacing(16, after: textView)
    }

    /// Renders every older version off the main thread, then adds them one
    /// per run-loop turn so a long history never stalls a frame for long.
    private func showOlder() {
        olderButton.configuration?.showsActivityIndicator = true
        olderButton.isEnabled = false
        let versions = olderVersions
        olderVersions = []
        Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { () -> Rendered in
                Rendered(texts: versions.map { Self.render(markdown: $0) }, older: [])
            }.value
            self?.olderButton.isHidden = true
            for text in rendered.texts {
                guard let self else { return }
                self.append(text)
                await Task.yield()
            }
        }
    }

    private nonisolated static func bundledChangelog() -> String {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            AppLogger.shared.warn("CHANGELOG.md missing from bundle", category: .app)
            return "The changelog isn't bundled in this build."
        }
        return text
    }

    /// Splits the changelog after the first `recent` versions that have
    /// entries: the intro and those versions as one block, then each older
    /// version on its own. A version heading with nothing under it (an empty
    /// Unreleased) is dropped.
    nonisolated static func split(markdown: String, recent: Int) -> (recent: String, older: [String]) {
        var preamble: [Substring] = []
        var sections: [[Substring]] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                sections.append([line])
            } else if sections.isEmpty {
                preamble.append(line)
            } else {
                sections[sections.count - 1].append(line)
            }
        }
        let versions = sections.filter { section in
            section.dropFirst().contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !isLinkReference(trimmed)
            }
        }
        let join = { (lines: [Substring]) in lines.joined(separator: "\n") }
        return (join(preamble + versions.prefix(recent).flatMap { $0 }), versions.dropFirst(recent).map(join))
    }

    /// A line-oriented markdown formatter for the changelog's shape: `##`
    /// version headings, `-` bullets with inline `**bold**`, plain paragraphs.
    /// The `# Changelog` title and the link-reference footer are dropped —
    /// the screen title and tappability already cover them.
    nonisolated static func render(markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let headingFont = UIFont.systemFont(ofSize: DesignSystem.Typography.title().pointSize - 2, weight: .bold)
        let bodyFont = DesignSystem.Typography.body()

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") { continue }
            if isLinkReference(trimmed) { continue }
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("## ") {
                if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
                let heading = trimmed.dropFirst(3)
                    .replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                out.append(NSAttributedString(string: heading + "\n\n", attributes: [
                    .font: headingFont, .foregroundColor: DesignSystem.Color.label,
                ]))
                continue
            }

            if trimmed.hasPrefix("- ") {
                out.append(bullet(String(trimmed.dropFirst(2)), font: bodyFont))
                continue
            }

            out.append(inline(trimmed, font: bodyFont, color: DesignSystem.Color.secondaryLabel))
            out.append(NSAttributedString(string: "\n\n"))
        }
        return out
    }

    /// `[unreleased]: https://…` style link-reference definitions at the foot
    /// of the file.
    private nonisolated static func isLinkReference(_ line: String) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return false }
        return line[line.index(after: close)...].hasPrefix(":")
    }

    private nonisolated static func bullet(_ text: String, font: UIFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 14
        paragraph.firstLineHeadIndent = 0
        paragraph.paragraphSpacing = 10
        let entry = NSMutableAttributedString(string: "•  ", attributes: [
            .font: font, .foregroundColor: DesignSystem.Color.accent, .paragraphStyle: paragraph,
        ])
        let body = inline(text, font: font, color: DesignSystem.Color.label).mutableCopy() as! NSMutableAttributedString
        body.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: body.length))
        entry.append(body)
        entry.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        return entry
    }

    private nonisolated static func inline(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        InlineMarkdown.render(text, font: font, color: color)
    }
}

#if DEBUG
extension ChangelogViewController {
    /// Screenshot-QA hook (`UNRAGER_SCREEN=changelog/end`): scrolls to the
    /// "Show older versions" button once the text has rendered.
    func debugScrollToEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            let bottom = self.scrollView.contentSize.height - self.scrollView.bounds.height
                + self.scrollView.adjustedContentInset.bottom
            self.scrollView.setContentOffset(CGPoint(x: 0, y: max(0, bottom)), animated: false)
        }
    }
}
#endif
