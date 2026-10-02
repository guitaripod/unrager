import UIKit

/// Inline markdown (bold, italic, code, links) as styled text in the caller's
/// base font and color. Foundation's parser only tags runs with a presentation
/// intent; it never changes the font, and an explicit font on the whole string
/// would hide the intent, so the weight and slant are applied here, run by run.
enum InlineMarkdown {
    static func render(_ markdown: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont(for: run.inlinePresentationIntent ?? [], base: font),
                .foregroundColor: color,
            ]
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = DesignSystem.Color.accent
            }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }

    private static func runFont(for intent: InlinePresentationIntent, base: UIFont) -> UIFont {
        if intent.contains(.code) {
            return .monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular)
        }
        var traits = base.fontDescriptor.symbolicTraits
        if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
        if intent.contains(.emphasized) { traits.insert(.traitItalic) }
        guard traits != base.fontDescriptor.symbolicTraits,
              let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }
}
