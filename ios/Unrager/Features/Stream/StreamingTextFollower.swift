import UIKit

/// Draws a streamed answer into a text view without stutter: tokens only ask
/// for a redraw, and bursts are coalesced into one rebuild every
/// `renderInterval` (re-parsing the whole answer's markdown per token is
/// quadratic and reflows faster than it can be read). While the reader sits at
/// the bottom the view follows the answer as it grows; dragging up to read
/// back stops that, and coming back to the bottom resumes it. Becomes the text
/// view's delegate to watch its scrolling.
@MainActor
final class StreamingTextFollower: NSObject, UITextViewDelegate {
    static let renderInterval: TimeInterval = 0.1
    static let tailSlack: CGFloat = 40

    private weak var textView: UITextView?
    private let content: () -> NSAttributedString
    private var pending: Task<Void, Never>?
    private(set) var followsTail = true

    init(textView: UITextView, content: @escaping () -> NSAttributedString) {
        self.textView = textView
        self.content = content
        super.init()
        textView.delegate = self
    }

    var isRenderPending: Bool { pending != nil }

    /// Asks for a redraw within `renderInterval`; further requests until then
    /// share it.
    func scheduleRender() {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.renderInterval))
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.renderNow()
        }
    }

    /// Redraws at once, dropping any coalesced redraw still waiting.
    func renderNow() {
        pending?.cancel()
        pending = nil
        guard let textView else { return }
        textView.attributedText = content()
        if followsTail { scrollToBottom(textView) }
    }

    /// Follows the answer again, for a new question or a retry.
    func resumeFollowing() {
        followsTail = true
    }

    /// Whether a scroll position shows the end of the content, within
    /// `tailSlack` points.
    static func isAtTail(offsetY: CGFloat, viewportHeight: CGFloat, bottomInset: CGFloat,
                         contentHeight: CGFloat) -> Bool {
        offsetY + viewportHeight - bottomInset >= contentHeight - tailSlack
    }

    private func scrollToBottom(_ textView: UITextView) {
        let length = textView.attributedText?.length ?? 0
        guard length > 0 else { return }
        textView.scrollRangeToVisible(NSRange(location: length - 1, length: 1))
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        followsTail = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        followsTail = Self.isAtTail(
            offsetY: scrollView.contentOffset.y, viewportHeight: scrollView.bounds.height,
            bottomInset: scrollView.adjustedContentInset.bottom, contentHeight: scrollView.contentSize.height)
    }
}
