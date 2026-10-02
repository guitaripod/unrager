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
    var onTapPlain: (() -> Void)?

    /// Whether a tap on plain text (not a link) is this view's own, reported to
    /// `onTapPlain`, instead of falling through to the cell.
    var capturesPlainTaps = false {
        didSet { plainTap.isEnabled = capturesPlainTaps }
    }

    private lazy var plainTap = UITapGestureRecognizer(target: self, action: #selector(plainTapped(_:)))

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
        plainTap.isEnabled = false
        addGestureRecognizer(plainTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Only a link glyph swallows the touch; taps on plain text fall through to
    /// the cell's `didSelectItemAt` so the body still opens the thread.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        capturesPlainTaps ? super.point(inside: point, with: event) : isLink(at: point)
    }

    private func isLink(at point: CGPoint) -> Bool {
        guard let position = closestPosition(to: point),
              let range = tokenizer.rangeEnclosingPosition(position, with: .character, inDirection: .layout(.left)) else {
            return false
        }
        let index = offset(from: beginningOfDocument, to: range.start)
        guard index >= 0, index < attributedText.length else { return false }
        return attributedText.attribute(.link, at: index, effectiveRange: nil) != nil
    }

    @objc private func plainTapped(_ gesture: UITapGestureRecognizer) {
        guard !isLink(at: gesture.location(in: self)) else { return }
        onTapPlain?()
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
