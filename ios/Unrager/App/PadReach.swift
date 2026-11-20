import UIKit

/// Where the reader's thumbs are. An iPad held on its side in both hands rests
/// a thumb on each side edge a little below the middle; the top of the screen
/// and its middle are a stretch. A window sharing the screen sits against one
/// screen edge, and only the thumb on that side reaches it — the other thumb is
/// on the other app. So the controls used most go low, and to that outer edge
/// when there is one. Pure, so every placement is testable without a window.
struct PadReach: Equatable {
    enum Side: Equatable {
        case leading
        case trailing
    }

    /// Whether the iPad is on its side, read from its screen rather than the
    /// window: a tall third of a landscape screen is still held in two hands.
    var heldSideways: Bool
    /// The screen edge this window sits against on its own, if it touches only
    /// one: a window filling the width touches both, a floating one neither.
    var outerEdge: Side?

    static let standard = PadReach(heldSideways: false, outerEdge: nil)

    /// The side the window's own primary control belongs on.
    var primarySide: Side { hugsSide ? outerEdge ?? .trailing : .trailing }

    /// Whether floating controls hug one side of the window instead of sitting
    /// where a portrait iPad expects them.
    var hugsSide: Bool { heldSideways && outerEdge != nil }

    /// Whether a rail down the window's leading edge sits under a thumb. A
    /// window sharing the screen from its trailing side has its leading edge in
    /// the middle of the screen, so its tabs belong in the bar along the bottom.
    var railInReach: Bool { !(heldSideways && outerEdge == .trailing) }

    /// Reads where a window of `window` (in screen points) sits on a screen of
    /// `screen`; the edges are compared with a point of slack for rounding.
    static func resolve(window: CGRect, screen: CGRect, rightToLeft: Bool) -> PadReach {
        let sideways = screen.width > screen.height
        let left = window.minX <= screen.minX + 1
        let right = window.maxX >= screen.maxX - 1
        let physical: Side? = switch (left, right) {
        case (true, false): .leading
        case (false, true): .trailing
        default: nil
        }
        let edge = physical.map { side -> Side in
            guard rightToLeft else { return side }
            return side == .leading ? .trailing : .leading
        }
        return PadReach(heldSideways: sideways, outerEdge: edge)
    }

    /// Reads it for the window `view` is in, in that view's own layout direction.
    @MainActor
    static func reading(_ view: UIView) -> PadReach {
        guard let screen = view.window?.windowScene?.screen else { return .standard }
        let frame = view.convert(view.bounds, to: screen.coordinateSpace)
        return resolve(window: frame, screen: screen.bounds,
                       rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
    }

    /// Posted when the system moves a window without resizing it, which no
    /// layout pass reports.
    static let windowMoved = Notification.Name("unrager.padReach.windowMoved")
}

extension PadReach {
    /// Where the floating tab bar and the compose button go along the bottom of
    /// a window `width` points wide: the bar's width and whether the button
    /// fits on the same line as the bar or has to sit above it.
    struct Dock: Equatable {
        enum Placement: Equatable {
            /// The bar centred, the button level with it in the corner.
            case centred
            /// The bar and the button side by side against one edge, the button
            /// outermost, under the thumb on that side.
            case hugging(Side)
        }

        var placement: Placement
        var barWidth: CGFloat
        /// Whether the button sits on the bar's line; otherwise it rides just
        /// above the bar's outer end.
        var composeBesideBar: Bool
        /// The side of the window the button is on.
        var composeSide: Side
    }

    static let dockMargin: CGFloat = 12
    static let dockGap: CGFloat = 10

    /// Lays the dock out for `tabs` tabs in a window `width` points wide, with a
    /// bar that would like `itemWidth` points per tab up to `maximumBar`, and a
    /// round compose button `button` points across.
    func dock(width: CGFloat, tabs: Int, itemWidth: CGFloat, maximumBar: CGFloat, button: CGFloat) -> Dock {
        let room = max(0, width - Self.dockMargin * 2)
        let natural = min(maximumBar, CGFloat(max(tabs, 1)) * itemWidth + 12)
        if hugsSide {
            let side = outerEdge ?? .trailing
            let beside = natural + Self.dockGap + button <= room
            return Dock(placement: .hugging(side),
                        barWidth: beside ? natural : min(natural, room),
                        composeBesideBar: beside, composeSide: side)
        }
        let bar = min(natural, room)
        let besideRoom = (width - bar) / 2 - Self.dockMargin
        let beside = besideRoom >= button + Self.dockGap
        return Dock(placement: .centred, barWidth: bar, composeBesideBar: beside, composeSide: .trailing)
    }
}
