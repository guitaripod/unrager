import Testing
import UIKit
@testable import Unrager

@MainActor
@Suite("Changelog rendering")
struct ChangelogRenderTests {
    @Test("Version headings, bullets and prose render; title and link refs are dropped")
    func rendersChangelogShape() {
        let markdown = """
        # Changelog

        Intro prose about the file.

        ## [Unreleased]

        - **A bold claim.** And its body.

        ## [0.20.0] — 2026-06-24

        - Plain bullet.

        [unreleased]: https://example.com/compare
        [0.20.0]: https://example.com/tag
        """
        let rendered = ChangelogViewController.render(markdown: markdown).string
        #expect(!rendered.contains("Changelog"))
        #expect(rendered.contains("Unreleased"))
        #expect(rendered.contains("0.20.0 — 2026-06-24"))
        #expect(rendered.contains("•  A bold claim. And its body."))
        #expect(rendered.contains("Intro prose about the file."))
        #expect(!rendered.contains("https://example.com"))
    }

    @Test("The bundled CHANGELOG.md ships in the app bundle")
    func changelogIsBundled() {
        let url = Bundle(for: ChangelogViewController.self).url(forResource: "CHANGELOG", withExtension: "md")
        #expect(url != nil)
    }
}

@MainActor
@Suite("Ask presets")
struct AskPresetTests {
    @Test("All five TUI presets exist and the replies preset is gated on replies")
    func presetGating() {
        #expect(AskConversationViewController.allPresets.count == 5)
        let withReplies = AskConversationViewController.presets(hasReplies: true)
        #expect(withReplies.count == 5)
        let withoutReplies = AskConversationViewController.presets(hasReplies: false)
        #expect(withoutReplies.count == 4)
        #expect(!withoutReplies.contains { $0.label == "Replies" })
    }
}
