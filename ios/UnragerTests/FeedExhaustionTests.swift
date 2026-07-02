import Testing
@testable import Unrager

@Suite("Feed exhaustion latch")
struct FeedExhaustionTests {
    @Test("A nil cursor latches immediately")
    func nilCursorLatches() {
        var latch = FeedExhaustion()
        latch.registerPage(added: 20, pageCursor: nil, requestCursor: nil, isReset: true)
        #expect(latch.isExhausted)
    }

    @Test("An echoed-back cursor on an empty non-reset page latches immediately")
    func cursorEchoLatches() {
        var latch = FeedExhaustion()
        latch.registerPage(added: 20, pageCursor: "c1", requestCursor: nil, isReset: true)
        latch.registerPage(added: 0, pageCursor: "c1", requestCursor: "c1", isReset: false)
        #expect(latch.isExhausted)
    }

    @Test("Fresh cursors with zero new tweets latch only after the empty-append limit")
    func emptyAppendRunLatches() {
        var latch = FeedExhaustion()
        latch.registerPage(added: 20, pageCursor: "c1", requestCursor: nil, isReset: true)
        for page in 0..<FeedExhaustion.emptyAppendLimit {
            #expect(!latch.isExhausted)
            latch.registerPage(added: 0, pageCursor: "c\(page + 2)",
                               requestCursor: "c\(page + 1)", isReset: false)
        }
        #expect(latch.isExhausted)
    }

    @Test("A page that adds tweets clears the empty-append run")
    func addedTweetsResetTheRun() {
        var latch = FeedExhaustion()
        latch.registerPage(added: 20, pageCursor: "c1", requestCursor: nil, isReset: true)
        latch.registerPage(added: 0, pageCursor: "c2", requestCursor: "c1", isReset: false)
        latch.registerPage(added: 0, pageCursor: "c3", requestCursor: "c2", isReset: false)
        latch.registerPage(added: 5, pageCursor: "c4", requestCursor: "c3", isReset: false)
        latch.registerPage(added: 0, pageCursor: "c5", requestCursor: "c4", isReset: false)
        latch.registerPage(added: 0, pageCursor: "c6", requestCursor: "c5", isReset: false)
        #expect(!latch.isExhausted)
        latch.registerPage(added: 0, pageCursor: "c7", requestCursor: "c6", isReset: false)
        #expect(latch.isExhausted)
    }

    @Test("Reset clears a latched feed and the empty-append run")
    func resetClearsTheLatch() {
        var latch = FeedExhaustion()
        latch.registerPage(added: 0, pageCursor: nil, requestCursor: nil, isReset: true)
        #expect(latch.isExhausted)
        latch.reset()
        #expect(!latch.isExhausted)
        latch.registerPage(added: 0, pageCursor: "c1", requestCursor: nil, isReset: true)
        #expect(!latch.isExhausted)
    }

    @Test("An empty reset page with a live cursor does not latch")
    func emptyResetPageDoesNotLatch() {
        var latch = FeedExhaustion()
        latch.registerPage(added: 0, pageCursor: "c1", requestCursor: nil, isReset: true)
        #expect(!latch.isExhausted)
    }
}
