import UIKit

/// Where an iPad window puts its tabs and its columns: a rail down the side of
/// a landscape window with a second column beside the feed, or a floating bar at
/// the bottom of a portrait or narrow one. Pure numbers, so the break points are
/// testable without a window.
struct PadLayout: Equatable {
    enum Chrome: Equatable {
        /// Tabs down the leading edge, the iPad's widest shape.
        case rail
        /// Tabs in a floating bar above the bottom edge.
        case bottom
    }

    var chrome: Chrome
    /// Width of the rail; zero when the chrome is a bar.
    var railWidth: CGFloat
    /// Width of the browsing column and of the detail column beside it. Both
    /// nil when the window only has room for one column, which then fills the
    /// space and caps its own reading width.
    var primaryWidth: CGFloat?
    var detailWidth: CGFloat?

    static let railWidth: CGFloat = 248
    static let narrowRailWidth: CGFloat = 216
    /// The gutter between the feed and the post opened beside it.
    static let columnGap: CGFloat = 24
    /// A window has to be at least this wide — and wider than it is tall —
    /// before the tabs move off the bottom.
    static let railWindowMinimum: CGFloat = 760
    /// Room the two columns need side by side: two posts at a comfortable
    /// measure, plus the gutter.
    static let twoColumnMinimum: CGFloat = 880

    /// Whether the window is wide enough to keep a post open beside the list.
    var showsDetail: Bool { detailWidth != nil }

    /// Resolves the chrome and the columns for a window of `window` points.
    static func resolve(window: CGSize) -> PadLayout {
        guard window.width > window.height, window.width >= railWindowMinimum else {
            return PadLayout(chrome: .bottom, railWidth: 0)
        }
        let rail = window.width >= 1000 ? railWidth : narrowRailWidth
        let content = window.width - rail
        guard content >= twoColumnMinimum else {
            return PadLayout(chrome: .rail, railWidth: rail)
        }
        let column = min(DesignSystem.maxContentWidth, ((content - columnGap) / 2).rounded(.down))
        return PadLayout(chrome: .rail, railWidth: rail, primaryWidth: column, detailWidth: column)
    }
}
