import UIKit

/// A non-editable, non-scrolling text view that renders a tweet body with
/// tappable `@mention` / `#hashtag` / link runs. Configured to behave like a
/// label: it sizes to its content, draws no chrome, and forwards every touch
/// that doesn't land on a link to the enclosing cell (so tapping the body still
/// opens the thread). Link taps are decoded back into `TweetText.Route`s and
/// dispatched to the per-kind closures.
final class TweetBodyTextView: UITextView, UITextViewDelegate {
    var onTapMention: ((String) -> Void)?
    var onTapHashtag: ((String) -> Void)?
    var onTapURL: ((URL) -> Void)?

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isScrollEnabled = false
        isSelectable = true
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
        delegate = self
        linkTextAttributes = [:]
        dataDetectorTypes = []
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Only a link glyph swallows the touch; taps on plain text fall through to
    /// the cell's `didSelectItemAt` so the body still opens the thread.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let position = closestPosition(to: point),
              let range = tokenizer.rangeEnclosingPosition(position, with: .character, inDirection: .layout(.left)) else {
            return false
        }
        let index = offset(from: beginningOfDocument, to: range.start)
        guard index >= 0, index < attributedText.length else { return false }
        return attributedText.attribute(.link, at: index, effectiveRange: nil) != nil
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        guard case let .link(url) = textItem.content else { return defaultAction }
        return UIAction { [weak self] _ in self?.route(url) }
    }

    private func route(_ url: URL) {
        switch TweetText.Route.from(url) {
        case let .profile(handle): onTapMention?(handle)
        case let .hashtag(query): onTapHashtag?(query)
        case let .url(target): onTapURL?(target)
        case nil: break
        }
    }
}
