import CoreGraphics
import Testing
@testable import Unrager

@Suite("Focal pin")
struct FocalPinTests {
    private func inset(_ pin: FocalPin, contentHeight: CGFloat = 900) -> CGFloat {
        pin.bottomInset(focalOffset: 600, viewportHeight: 874, contentHeight: contentHeight, safeAreaBottom: 34)
    }

    @Test("A held pin pads just enough for a focal near the end of a thread to reach the top")
    func heldPinPadsTheShortfall() {
        var pin = FocalPin()
        pin.hold()
        #expect(inset(pin) == CGFloat(540))
    }

    @Test("A held pin over a thread long enough to scroll asks for no padding")
    func longThreadNeedsNone() {
        var pin = FocalPin()
        pin.hold()
        #expect(inset(pin, contentHeight: 3000) == 0)
    }

    @Test("Once the reader takes over, the pin leaves no empty space under the conversation")
    func releasedPinPadsNothing() {
        var pin = FocalPin()
        pin.hold()
        pin.release()
        #expect(!pin.isHeld)
        #expect(inset(pin) == 0)
    }

    @Test("A thread that was never pinned is never padded")
    func unheldPinPadsNothing() {
        #expect(inset(FocalPin()) == 0)
    }
}
