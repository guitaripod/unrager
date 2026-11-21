import UIKit

/// Where an iPad window puts its tabs and its board: a rail down the side of a
/// wide window with the board beside it, or, in a tall or narrow window, a
/// floating bar along the bottom. A post opens over the board on the tab's own
/// stack (`PostOpening`), so it needs no room of its own here. Pure numbers, so
/// every break point is testable without a window.
struct PadLayout: Equatable {
    enum Chrome: Equatable {
        /// Tabs down the leading edge, the iPad's widest shape.
        case rail
        /// Tabs in a floating bar above the bottom edge.
        case bottom
    }

    /// The iPad this window is on. A mini is the same idea with less room:
    /// a narrower rail, and a third post across only where the width has room
    /// for it, which is a landscape window with the sidebar closed.
    enum Frame: Equatable {
        case mini
        case regular

        /// A mini's screen is 744 pt on its short side and an 11-inch iPad's 834,
        /// so the short side of the *screen* tells them apart in either
        /// orientation. Never the window's: a short window on a 13-inch iPad is
        /// still a 13-inch iPad's window, with its thumbs and its type.
        static func of(_ screen: CGSize) -> Frame {
            min(screen.width, screen.height) <= 780 ? .mini : .regular
        }
    }

    /// Every number that changes between a mini and a full-size window.
    struct Metrics: Equatable {
        /// The rail's width when the reader has never dragged it.
        var rail: CGFloat
        var narrowestRail: CGFloat
        var widestRail: CGFloat
        /// The most posts the board may set side by side.
        var boardColumns: Int
        /// How narrow a post may get before the board drops a column.
        var boardColumnWidth: CGFloat
        /// The floating bar's height, and the room a list keeps clear under it.
        var barHeight: CGFloat
        var barClearance: CGFloat
        /// The widest the floating bar grows, and the room it would like per tab
        /// before it is squeezed.
        var barWidth: CGFloat
        var barItemWidth: CGFloat
        /// How much of the window's width the rail may claim.
        var railShare: CGFloat
    }

    private static let profiles: [Frame: Metrics] = [
        .regular: Metrics(
            rail: 280, narrowestRail: 232, widestRail: 380,
            boardColumns: 3, boardColumnWidth: 300,
            barHeight: 62, barClearance: 84, barWidth: 560, barItemWidth: 86, railShare: 0.26),
        .mini: Metrics(
            rail: 208, narrowestRail: 188, widestRail: 264,
            boardColumns: 3, boardColumnWidth: 300,
            barHeight: 56, barClearance: 78, barWidth: 470, barItemWidth: 78, railShare: 0.3),
    ]

    /// A window has to be at least this wide — and wider than it is tall —
    /// before the tabs move off the bottom. Below it a rail would leave the feed
    /// a single starved column: two thirds of an 11-inch iPad on its side, or a
    /// short window across the top of a portrait one, keep the bar and get a
    /// board of two instead.
    static let railWindowMinimum: CGFloat = 900

    /// Whether a window this shape has room for the rail at all.
    static func allowsRail(window: CGSize) -> Bool {
        window.width > window.height && window.width >= railWindowMinimum
    }

    static func metrics(for frame: Frame) -> Metrics {
        profiles[frame] ?? profiles[.regular]!
    }

    var chrome: Chrome
    var frame: Frame
    var railWidth: CGFloat
    /// The cap on the board's columns, before the width decides.
    var boardColumns: Int

    var metrics: Metrics { Self.metrics(for: frame) }

    /// Resolves the chrome and the columns for a window of `window` points on a
    /// screen of `screen` points (the window itself when unknown), with the
    /// sidebar at `rail` points wide — or `0` for the frame's own default — and
    /// closed, which gives its room back to the columns.
    static func resolve(window: CGSize, screen: CGSize? = nil, rail: CGFloat = 0,
                        closed: Bool = false) -> PadLayout {
        let frame = Frame.of(screen ?? window)
        let metrics = metrics(for: frame)
        let tall = PadLayout(chrome: .bottom, frame: frame, railWidth: 0, boardColumns: metrics.boardColumns)
        guard allowsRail(window: window), !closed else {
            return tall
        }
        // A rail is a slice of the window, never a fifth of a mini's screen.
        let share = min(metrics.widestRail, max(metrics.narrowestRail,
                                                (window.width * metrics.railShare).rounded()))
        let width = min(max(rail > 0 ? rail : metrics.rail, metrics.narrowestRail), share)
        return PadLayout(chrome: .rail, frame: frame, railWidth: width, boardColumns: metrics.boardColumns)
    }

    /// The narrowest board that still sets two posts side by side.
    static func twoColumnBoard(_ metrics: Metrics) -> CGFloat {
        metrics.boardColumnWidth * 2 + 10 + 20
    }

    /// How the feed's board takes shape in a window of `window` points: the
    /// narrowest a post may get, the most that may sit side by side, and the
    /// widest the board itself grows. A tall window sets two across — three
    /// narrow columns of text in portrait read worse than two wider ones — and
    /// a landscape window sets three where they fit: a mini's does with its
    /// sidebar closed, and keeps two beside an open one.
    static func board(window: CGSize, screen: CGSize? = nil) -> Board {
        let frame = Frame.of(screen ?? window)
        let metrics = metrics(for: frame)
        let columns = allowsRail(window: window) ? metrics.boardColumns : 2
        return Board(minimumColumnWidth: metrics.boardColumnWidth,
                     maximumColumns: columns,
                     maximumWidth: CGFloat(columns) * 480,
                     dense: frame == .mini)
    }

    /// The feed board's shape, as `MasonryLayout` takes it.
    struct Board: Equatable {
        var minimumColumnWidth: CGFloat
        var maximumColumns: Int
        var maximumWidth: CGFloat
        /// A mini's gutters close up: the same board in less room.
        var dense: Bool
    }
}
