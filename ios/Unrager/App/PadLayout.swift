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
    /// Width of the rail; zero when the chrome is a bar, or when the reader has
    /// closed the sidebar.
    var railWidth: CGFloat
    /// Width of the panel a post opens into. Nil in a narrow window, where the
    /// panel is inset across the whole board instead of sitting beside it.
    var detailWidth: CGFloat?

    /// Room the board keeps when a post opens beside it: one comfortable
    /// column. Below this the panel lies across the board instead.
    static let minimumBoardWidth: CGFloat = 380
    static let minimumPanelWidth: CGFloat = 340
    static let railWidth: CGFloat = 248
    static let narrowestRailWidth: CGFloat = 200
    static let widestRailWidth: CGFloat = 360
    /// The gutter between the feed and the post opened beside it.
    static let columnGap: CGFloat = 24
    /// A window has to be at least this wide — and wider than it is tall —
    /// before the tabs move off the bottom.
    static let railWindowMinimum: CGFloat = 760

    /// Whether the window is wide enough to keep a post open beside the board.
    var showsDetail: Bool { detailWidth != nil }

    /// Resolves the chrome and the columns for a window of `window` points, with
    /// the sidebar at `rail` points wide — or closed, which gives its room back
    /// to the columns.
    static func resolve(window: CGSize, rail: CGFloat = railWidth, closed: Bool = false) -> PadLayout {
        guard window.width > window.height, window.width >= railWindowMinimum else {
            return PadLayout(chrome: .bottom, railWidth: 0)
        }
        let width = closed ? 0 : min(max(rail, narrowestRailWidth), widestRailWidth)
        let content = window.width - width
        let panel = min(560, content - Self.minimumBoardWidth)
        return PadLayout(chrome: .rail, railWidth: width,
                         detailWidth: panel >= Self.minimumPanelWidth ? panel : nil)
    }
}
