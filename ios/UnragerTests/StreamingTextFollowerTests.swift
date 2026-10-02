import Testing
import UIKit
@testable import Unrager

@MainActor
@Suite("Streaming answer rendering")
struct StreamingTextFollowerTests {
    @Test("A burst of tokens is drawn once, after the coalescing interval")
    func coalescesBursts() async throws {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        var builds = 0
        var answer = ""
        let follower = StreamingTextFollower(textView: textView) {
            builds += 1
            return NSAttributedString(string: answer)
        }
        for token in ["one ", "two ", "three"] {
            answer += token
            follower.scheduleRender()
        }
        #expect(builds == 0)
        #expect(follower.isRenderPending)
        try await Task.sleep(for: .seconds(StreamingTextFollower.renderInterval * 4))
        #expect(builds == 1)
        #expect(textView.text == "one two three")
        #expect(!follower.isRenderPending)
    }

    @Test("Drawing at once drops the coalesced draw still waiting")
    func renderNowCancelsPending() async throws {
        let textView = UITextView()
        var builds = 0
        let follower = StreamingTextFollower(textView: textView) {
            builds += 1
            return NSAttributedString(string: "done")
        }
        follower.scheduleRender()
        follower.renderNow()
        #expect(builds == 1)
        try await Task.sleep(for: .seconds(StreamingTextFollower.renderInterval * 4))
        #expect(builds == 1)
    }

    @Test("The view follows the answer only while the reader is at its end")
    func tailDetection() {
        #expect(StreamingTextFollower.isAtTail(offsetY: 600, viewportHeight: 400, bottomInset: 0, contentHeight: 1000))
        #expect(StreamingTextFollower.isAtTail(offsetY: 570, viewportHeight: 400, bottomInset: 0, contentHeight: 1000))
        #expect(!StreamingTextFollower.isAtTail(offsetY: 300, viewportHeight: 400, bottomInset: 0, contentHeight: 1000))
        #expect(!StreamingTextFollower.isAtTail(offsetY: 600, viewportHeight: 400, bottomInset: 100, contentHeight: 1000))
    }

    @Test("Becomes the text view's delegate and starts out following")
    func wiring() {
        let textView = UITextView()
        let follower = StreamingTextFollower(textView: textView) { NSAttributedString() }
        #expect(textView.delegate === follower)
        #expect(follower.followsTail)
        follower.scrollViewWillBeginDragging(textView)
        #expect(!follower.followsTail)
        follower.resumeFollowing()
        #expect(follower.followsTail)
    }
}
