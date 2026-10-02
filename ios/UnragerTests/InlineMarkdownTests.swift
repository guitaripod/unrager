import Testing
import UIKit
@testable import Unrager

@MainActor
@Suite("Inline markdown")
struct InlineMarkdownTests {
    private func font(in text: NSAttributedString, at fragment: String) -> UIFont {
        let range = (text.string as NSString).range(of: fragment)
        return text.attribute(.font, at: range.location, effectiveRange: nil) as! UIFont
    }

    @Test("Bold, italic and code runs get matching fonts; plain text keeps the base font")
    func intentsBecomeFonts() {
        let rendered = InlineMarkdown.render("plain **strong** _slanted_ `mono`",
                                             font: .systemFont(ofSize: 16), color: .label)
        #expect(!font(in: rendered, at: "plain").fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(font(in: rendered, at: "strong").fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(font(in: rendered, at: "slanted").fontDescriptor.symbolicTraits.contains(.traitItalic))
        #expect(font(in: rendered, at: "mono").fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    @Test("Markdown markers don't survive into the text, and newlines are kept")
    func markersAreConsumed() {
        let rendered = InlineMarkdown.render("**a**\nb", font: .systemFont(ofSize: 16), color: .label)
        #expect(rendered.string == "a\nb")
    }
}
