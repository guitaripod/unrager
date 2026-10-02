import UIKit

/// A label for a post's text that can still be tapped on its `@mentions`,
/// `#hashtags` and links. A `UITextView` builds a whole text system for every
/// row it sits in, and was the heaviest part of binding and sizing a post; a
/// label is a fraction of that, and the text system is only built, briefly, to
/// find what was under a finger.
///
/// Like a label it sizes to its text and draws no chrome, and it forwards every
/// touch that doesn't land on a link to the enclosing cell (so tapping the text
/// still opens the thread), unless `capturesPlainTaps` says a tap anywhere on
/// it is its own. Link taps are decoded back into `TweetText.Route`s and
/// dispatched to the per-kind closures.
final class LinkLabel: UILabel {
    var onTapMention: ((String) -> Void)?
    var onTapHashtag: ((String) -> Void)?
    var onTapURL: ((URL) -> Void)?
    var onTapPlain: (() -> Void)?

    /// Whether a tap on plain text (not a link) is this view's own, reported to
    /// `onTapPlain`, instead of falling through to the cell.
    var capturesPlainTaps = false

    var textInsets = UIEdgeInsets.zero {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines lines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: textInsets), limitedToNumberOfLines: lines)
        return CGRect(x: inner.origin.x - textInsets.left, y: inner.origin.y - textInsets.top,
                      width: inner.width + textInsets.left + textInsets.right,
                      height: inner.height + textInsets.top + textInsets.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    /// Only a link swallows the touch; taps on plain text fall through to the
    /// cell's `didSelectItemAt` so the text still opens the thread.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        return capturesPlainTaps || link(at: point) != nil
    }

    /// The link under `point`, found by laying the text out the way the label
    /// does and asking which character it landed on.
    private func link(at point: CGPoint) -> URL? {
        guard let text = attributedText, text.length > 0 else { return nil }
        let area = bounds.inset(by: textInsets)
        guard area.contains(point) else { return nil }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: area.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        container.lineBreakMode = lineBreakMode
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let used = manager.usedRect(for: container)
        let local = CGPoint(x: point.x - area.minX, y: point.y - area.minY)
        guard used.contains(local) else { return nil }
        let glyph = manager.glyphIndex(for: local, in: container)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.contains(local) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < text.length else { return nil }
        return text.attribute(TweetText.linkKey, at: index, effectiveRange: nil) as? URL
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let url = link(at: gesture.location(in: self)) else {
            if capturesPlainTaps { onTapPlain?() }
            return
        }
        switch TweetText.Route.from(url) {
        case let .profile(handle): onTapMention?(handle)
        case let .hashtag(query): onTapHashtag?(query)
        case let .url(target): onTapURL?(target)
        case nil: break
        }
    }
}
