import AppKit

/// An `NSButton` that tells a quick click apart from a press-and-hold. A click
/// fires the button's normal target/action; holding past `holdThreshold` fires
/// `onLongPress` instead and suppresses the click. Long-press is opt-in per use
/// via `longPressEnabled`, so buttons that leave it off behave exactly like a
/// plain `NSButton`.
///
/// Detection uses a manual mouse-tracking loop rather than an
/// `NSPressGestureRecognizer` because `NSButton`'s own `mouseDown` tracking loop
/// swallows the events a recognizer would otherwise receive.
final class LongPressButton: NSButton {
    var onLongPress: (() -> Void)?
    var longPressEnabled = false

    private static let holdThreshold: TimeInterval = 0.35

    override func mouseDown(with event: NSEvent) {
        guard longPressEnabled, onLongPress != nil, let window else {
            super.mouseDown(with: event)
            return
        }
        trackHold(in: window)
    }

    private func trackHold(in window: NSWindow) {
        let deadline = Date(timeIntervalSinceNow: Self.holdThreshold)
        var inside = true
        isHighlighted = true
        while true {
            if Date() >= deadline {
                isHighlighted = false
                if inside { onLongPress?() }
                return
            }
            guard let next = window.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: deadline, inMode: .eventTracking, dequeue: true)
            else { continue }
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isHighlighted = inside
            if next.type == .leftMouseUp {
                isHighlighted = false
                if inside, let action { sendAction(action, to: target) }
                return
            }
        }
    }
}
