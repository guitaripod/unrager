import Testing
import UIKit
@testable import Unrager

@Suite("Feed body truncation")
struct TweetBodyLimitTests {
    @MainActor
    private func body(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: DesignSystem.Typography.body()])
    }

    @Test("A note-length body exceeds the feed cap")
    @MainActor
    func longBodyExceeds() {
        let text = Array(repeating: "line of text", count: 30).joined(separator: "\n")
        #expect(TweetCell.bodyExceedsLimit(body(text), limit: TweetCell.feedBodyLineLimit, contentWidth: 300))
    }

    @Test("A short body never truncates")
    @MainActor
    func shortBodyFits() {
        #expect(!TweetCell.bodyExceedsLimit(body("just one line"), limit: TweetCell.feedBodyLineLimit,
                                            contentWidth: 300))
        let text = Array(repeating: "line", count: 5).joined(separator: "\n")
        #expect(!TweetCell.bodyExceedsLimit(body(text), limit: TweetCell.feedBodyLineLimit, contentWidth: 300))
    }

    @Test("A body barely past the cap stays untruncated (hysteresis)")
    @MainActor
    func slackKeepsMarginalBodies() {
        let text = Array(repeating: "line", count: TweetCell.feedBodyLineLimit + 2).joined(separator: "\n")
        #expect(!TweetCell.bodyExceedsLimit(body(text), limit: TweetCell.feedBodyLineLimit, contentWidth: 300))
    }

    @Test("Zero limit means unlimited")
    @MainActor
    func focalUnlimited() {
        let text = Array(repeating: "line", count: 40).joined(separator: "\n")
        #expect(TweetCell.bodyExceedsLimit(body(text), limit: 10, contentWidth: 300))
        #expect(!TweetCell.bodyExceedsLimit(body(text), limit: 100, contentWidth: 300))
    }
}
