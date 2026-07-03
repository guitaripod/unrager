import UIKit
import UnragerKit

/// "What's new": renders the bundled `CHANGELOG.md` as formatted, read-only
/// text — version headings, bulleted entries with inline bold — entirely
/// offline (the file ships in the app bundle).
final class ChangelogViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "What's new"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never

        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.textContainerInset = .init(top: 16, left: 16, bottom: 32, right: 16)
        textView.adjustsFontForContentSizeCategory = true
        view.addManaged(textView)
        textView.pinEdges(toSafeAreaOf: view)

        textView.attributedText = Self.render(markdown: Self.bundledChangelog())
    }

    private static func bundledChangelog() -> String {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            AppLogger.shared.warn("CHANGELOG.md missing from bundle", category: .app)
            return "The changelog isn't bundled in this build."
        }
        return text
    }

    /// A line-oriented markdown formatter for the changelog's shape: `##`
    /// version headings, `-` bullets with inline `**bold**`, plain paragraphs.
    /// The `# Changelog` title and the link-reference footer are dropped —
    /// the screen title and tappability already cover them.
    static func render(markdown: String) -> NSAttributedString {
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
    private static func isLinkReference(_ line: String) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return false }
        return line[line.index(after: close)...].hasPrefix(":")
    }

    private static func bullet(_ text: String, font: UIFont) -> NSAttributedString {
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

    /// Inline markdown (bold, code) via Foundation's parser, with the base
    /// font/color merged in.
    private static func inline(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        var base = AttributeContainer()
        base.font = font
        base.foregroundColor = color
        attributed.mergeAttributes(base, mergePolicy: .keepNew)
        return NSAttributedString(attributed)
    }
}
