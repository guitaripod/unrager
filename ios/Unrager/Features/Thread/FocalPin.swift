import CoreGraphics

/// Holds a thread opened by id (a notification, a "Replying to" caption, a
/// link) on its focal post while the ancestors above it load and grow. Near
/// the end of a conversation there isn't enough below the focal to scroll it to
/// the top, so a held pin pads the bottom by just the missing amount. The
/// padding belongs to the pin: once the reader takes over (a drag, a posted
/// reply) the pin lets go and asks for none, so it can never stay behind as
/// empty space under the conversation.
struct FocalPin: Equatable {
    private(set) var isHeld = false

    mutating func hold() { isHeld = true }

    mutating func release() { isHeld = false }

    /// The bottom inset that lets the scroll view rest at `focalOffset` (the
    /// offset that puts the focal under the navigation bar) with
    /// `contentHeight` of rows in a `viewportHeight` tall view whose safe area
    /// already keeps `safeAreaBottom` clear: what's missing below the last row,
    /// never negative, and nothing at all once the pin has let go.
    func bottomInset(focalOffset: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat,
                     safeAreaBottom: CGFloat) -> CGFloat {
        guard isHeld else { return 0 }
        return max(0, focalOffset + viewportHeight - contentHeight - safeAreaBottom)
    }
}
