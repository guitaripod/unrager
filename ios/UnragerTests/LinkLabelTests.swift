import Testing
import UIKit
@testable import Unrager

@MainActor
@Suite("Link label")
struct LinkLabelTests {
    private let font = UIFont.systemFont(ofSize: 17)

    private func label(_ text: String, linking fragment: String, route: String = "unrager://profile/alice") -> LinkLabel {
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font])
        let range = (text as NSString).range(of: fragment)
        attributed.addAttribute(TweetText.linkKey, value: URL(string: route)!, range: range)
        let label = LinkLabel(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        label.font = font
        label.attributedText = attributed
        return label
    }

    private func midpoint(of fragment: String, in text: String) -> CGPoint {
        let ns = text as NSString
        let range = ns.range(of: fragment)
        let before = ns.substring(to: range.location).size(withAttributes: [.font: font]).width
        let width = fragment.size(withAttributes: [.font: font]).width
        return CGPoint(x: before + width / 2, y: font.lineHeight / 2)
    }

    @Test("A touch on a link is the label's own, a touch on plain text falls through")
    func onlyLinksSwallowTouches() {
        let text = "hello @alice and more"
        let label = label(text, linking: "@alice")
        #expect(label.point(inside: midpoint(of: "@alice", in: text), with: nil))
        #expect(!label.point(inside: midpoint(of: "hello", in: text), with: nil))
        #expect(!label.point(inside: CGPoint(x: 250, y: 100), with: nil))
    }

    @Test("A caption that captures plain taps takes a touch anywhere on it")
    func capturingLabelTakesEveryTouch() {
        let text = "Replying to @alice"
        let label = label(text, linking: "@alice")
        label.capturesPlainTaps = true
        #expect(label.point(inside: midpoint(of: "Replying", in: text), with: nil))
    }

    @Test("Insets move the text, and the link with it")
    func insetsShiftHitTesting() {
        let text = "hello @alice"
        let label = label(text, linking: "@alice")
        label.textInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        var point = midpoint(of: "@alice", in: text)
        point.x += 16
        #expect(label.point(inside: point, with: nil))
        #expect(!label.point(inside: CGPoint(x: 4, y: 4), with: nil))
    }
}
