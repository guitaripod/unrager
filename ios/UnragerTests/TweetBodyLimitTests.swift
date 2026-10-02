import Testing
import UIKit
import UnragerKit
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

    @MainActor
    private func longTweet() throws -> Tweet {
        let text = (1...40).map { "line \($0) of a long note" }.joined(separator: "\n")
        let json = """
        {"rest_id":"1","author":{"rest_id":"2","handle":"a","name":"A","verified":false,
          "followers":0,"following":0},"created_at":"2026-06-19T12:00:00Z","text":"\(text.replacingOccurrences(of: "\n", with: "\\n"))",
          "reply_count":0,"retweet_count":0,"like_count":0,"quote_count":0,
          "bookmark_count":0,"retweeted":false,"bookmarked":false,
          "url":"https://x.com/a/status/1"}
        """
        return try UnragerJSON.decode(Tweet.self, from: Data(json.utf8))
    }

    @MainActor
    private func height(of cell: TweetCell, width: CGFloat) -> CGFloat {
        cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
    }

    @Test("Reconfiguring a truncated row with no limit makes it taller")
    @MainActor
    func showMoreGrowsTheRow() throws {
        let tweet = try longTweet()
        let cell = TweetCell(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        cell.configure(with: tweet, imagesEnabled: false, contentWidth: 300,
                       bodyLineLimit: TweetCell.feedBodyLineLimit)
        let collapsed = height(of: cell, width: 390)
        cell.configure(with: tweet, imagesEnabled: false, contentWidth: 300, bodyLineLimit: 0)
        let expanded = height(of: cell, width: 390)
        #expect(expanded > collapsed + 100)
    }

    @MainActor
    private func pump(_ seconds: TimeInterval = 0.5) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @MainActor
    private func showMoreButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.configuration?.title == "Show more" { return button }
        for sub in view.subviews { if let found = showMoreButton(in: sub) { return found } }
        return nil
    }

    @Test("Show more on a feed row expands it and the button is hittable")
    @MainActor
    func feedRowExpands() async throws {
        let tweet = try longTweet()
        let model = TimelineViewModel(source: .user(handle: "a"))
        model.tweets.send([tweet])
        let feed = FeedViewController(viewModel: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = feed
        window.makeKeyAndVisible()
        await pump()
        let cell = try #require(feed.tweetCell(for: tweet))
        let button = try #require(showMoreButton(in: cell))
        #expect(!button.isHidden)
        let collapsed = cell.bounds.height
        let center = button.convert(CGPoint(x: button.bounds.minX + 20, y: button.bounds.midY), to: cell)
        let bottom = button.convert(CGPoint(x: button.bounds.minX + 20, y: button.bounds.maxY - 1), to: cell)
        #expect(cell.hitTest(center, with: nil) === button || cell.hitTest(center, with: nil)?.isDescendant(of: button) == true)
        #expect(cell.hitTest(bottom, with: nil) === button || cell.hitTest(bottom, with: nil)?.isDescendant(of: button) == true)
        button.sendActions(for: .touchUpInside)
        await pump()
        let expandedCell = try #require(feed.tweetCell(for: tweet))
        #expect(expandedCell.bounds.height > collapsed + 100)
    }
}
