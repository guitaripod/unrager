import UIKit

/// Where an iPad window puts its tabs and its columns: a rail down the side of
/// a wide window, the board beside it and — when the board can spare the room —
/// a real second column for the post you open; or, in a tall or narrow window,
/// a floating bar along the bottom, where a post takes the whole window the way
/// it does on the phone. Pure numbers, so every break point is testable without
/// a window.
struct PadLayout: Equatable {
    enum Chrome: Equatable {
        /// Tabs down the leading edge, the iPad's widest shape.
        case rail
        /// Tabs in a floating bar above the bottom edge.
        case bottom
    }

    /// The iPad this window is on. A mini is the same idea with less room:
    /// a narrower rail, a narrower column, and never more than two posts across.
    enum Frame: Equatable {
        case mini
        case regular

        /// A mini portrait window is 744 pt across and an 11-inch iPad 834, so
        /// the short side is what tells them apart in either orientation.
        static func of(_ window: CGSize) -> Frame {
            min(window.width, window.height) <= 780 ? .mini : .regular
        }
    }

    /// Every number that changes between a mini and a full-size window.
    struct Metrics: Equatable {
        /// The rail's width when the reader has never dragged it.
        var rail: CGFloat
        var narrowestRail: CGFloat
        var widestRail: CGFloat
        /// The range the column a post opens into may take.
        var detail: ClosedRange<CGFloat>
        /// The most posts the board may set side by side.
        var boardColumns: Int
        /// How narrow a post may get before the board drops a column.
        var boardColumnWidth: CGFloat
        /// The floating bar's height, and the room a list keeps clear under it.
        var barHeight: CGFloat
        var barClearance: CGFloat
        /// The widest the floating bar grows.
        var barWidth: CGFloat
        /// How much of the window's width the rail may claim.
        var railShare: CGFloat
    }

    private static let profiles: [Frame: Metrics] = [
        .regular: Metrics(
            rail: 280, narrowestRail: 232, widestRail: 380,
            detail: 400...600, boardColumns: 3, boardColumnWidth: 300,
            barHeight: 62, barClearance: 84, barWidth: 560, railShare: 0.26),
        .mini: Metrics(
            rail: 208, narrowestRail: 188, widestRail: 264,
            detail: 340...440, boardColumns: 2, boardColumnWidth: 300,
            barHeight: 56, barClearance: 78, barWidth: 470, railShare: 0.3),
    ]

    /// A window has to be at least this wide — and wider than it is tall —
    /// before the tabs move off the bottom.
    static let railWindowMinimum: CGFloat = 700

    static func metrics(for frame: Frame) -> Metrics {
        profiles[frame] ?? profiles[.regular]!
    }

    var chrome: Chrome
    var frame: Frame
    var railWidth: CGFloat
    /// Width of the column a post opens into. Nil where the window has no room
    /// for it, and the post fills the window instead.
    var detailWidth: CGFloat?
    /// The cap on the board's columns, before the width decides.
    var boardColumns: Int

    var metrics: Metrics { Self.metrics(for: frame) }

    /// Whether the window is wide enough to keep a post open beside the board.
    var showsDetail: Bool { detailWidth != nil }

    /// Resolves the chrome and the columns for a window of `window` points, with
    /// the sidebar at `rail` points wide — or `0` for the frame's own default —
    /// and closed, which gives its room back to the columns.
    static func resolve(window: CGSize, rail: CGFloat = 0, closed: Bool = false) -> PadLayout {
        let frame = Frame.of(window)
        let metrics = metrics(for: frame)
        let tall = PadLayout(chrome: .bottom, frame: frame, railWidth: 0,
                             detailWidth: nil, boardColumns: metrics.boardColumns)
        guard window.width > window.height, window.width >= railWindowMinimum, !closed else {
            return tall
        }
        // A rail is a slice of the window, never a fifth of a mini's screen.
        let share = min(metrics.widestRail, max(metrics.narrowestRail,
                                                (window.width * metrics.railShare).rounded()))
        let width = min(max(rail > 0 ? rail : metrics.rail, metrics.narrowestRail), share)
        let content = window.width - width
        let wanted = min(metrics.detail.upperBound,
                         max(metrics.detail.lowerBound, (content * 0.38).rounded()))
        // The column takes what the board can spare: a card beside it, two where
        // the window has that much. Where not even one fits, a post fills the
        // window instead and the board waits behind it.
        let detail = content - wanted >= metrics.boardColumnWidth + 30 ? wanted : nil
        return PadLayout(chrome: .rail, frame: frame, railWidth: width,
                         detailWidth: detail, boardColumns: metrics.boardColumns)
    }

    /// How the feed's board takes shape in a window of `window` points: the
    /// narrowest a post may get, the most that may sit side by side, and the
    /// widest the board itself grows. A tall window sets two across — three
    /// narrow columns of text in portrait read worse than two wider ones — and
    /// a full-size landscape window sets three.
    static func board(window: CGSize) -> Board {
        let metrics = metrics(for: Frame.of(window))
        let landscape = window.width > window.height && window.width >= railWindowMinimum
        let columns = landscape ? metrics.boardColumns : 2
        return Board(minimumColumnWidth: metrics.boardColumnWidth,
                     maximumColumns: columns,
                     maximumWidth: CGFloat(columns) * 480,
                     dense: Frame.of(window) == .mini)
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
