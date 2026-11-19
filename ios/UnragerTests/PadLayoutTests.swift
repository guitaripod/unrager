import Foundation
import Testing
import UIKit
@testable import Unrager

@Suite("Pad layout")
struct PadLayoutTests {
    @Test("A tall window puts the tabs on the bottom, in one column")
    func portrait() {
        let layout = PadLayout.resolve(window: CGSize(width: 1032, height: 1376))
        #expect(layout.chrome == .bottom)
        #expect(layout.railWidth == 0)
        #expect(!layout.showsDetail)
    }

    @Test("A wide window puts the tabs on the side, with a column beside the feed")
    func landscape() {
        let layout = PadLayout.resolve(window: CGSize(width: 1376, height: 1032))
        #expect(layout.chrome == .rail)
        #expect(layout.railWidth == PadLayout.metrics(for: .regular).rail)
        #expect(layout.showsDetail)
        let column = try? #require(layout.detailWidth)
        let metrics = PadLayout.metrics(for: .regular)
        #expect(metrics.detail.contains(column ?? 0))
        #expect(1376 - layout.railWidth - (column ?? 0) >= metrics.boardColumnWidth)
    }

    @Test("A rail dragged narrow is clamped to the band its grip allows")
    func narrowLandscape() {
        let layout = PadLayout.resolve(window: CGSize(width: 1376, height: 1032), rail: 80)
        #expect(layout.chrome == .rail)
        #expect(layout.railWidth == PadLayout.metrics(for: .regular).narrowestRail)
    }

    @Test("A third of the screen is one column with the bar at the bottom")
    func narrowWindow() {
        let layout = PadLayout.resolve(window: CGSize(width: 620, height: 1000))
        #expect(layout.chrome == .bottom)
        #expect(layout.railWidth == 0)
        #expect(!layout.showsDetail)
        #expect(MasonryLayout.columns(for: 604) == 1)
        #expect(PadLayout.board(window: CGSize(width: 620, height: 1000)).maximumColumns == 2)
    }

    @Test("Slide Over keeps the bottom bar whatever the height")
    func slideOver() {
        let layout = PadLayout.resolve(window: CGSize(width: 320, height: 900))
        #expect(layout.chrome == .bottom)
        #expect(!layout.showsDetail)
    }

    @Test("The column keeps a reading measure and never eats the board")
    func wideWindow() {
        let window = CGSize(width: 2400, height: 1000)
        let layout = PadLayout.resolve(window: window)
        let column = layout.detailWidth ?? 0
        let metrics = layout.metrics
        #expect(metrics.detail.contains(column))
        #expect(window.width - layout.railWidth - column > 1200)
    }

    @Test("A column opens beside a one-column board in a split window")
    func splitWindowPanel() {
        let window = CGSize(width: 990, height: 744)
        let layout = PadLayout.resolve(window: window)
        #expect(layout.chrome == .rail)
        let column = layout.detailWidth ?? 0
        let metrics = layout.metrics
        #expect(column >= metrics.detail.lowerBound)
        #expect(window.width - layout.railWidth - column >= metrics.boardColumnWidth)
    }

    @Test("The column always leaves the board a readable one")
    func panelFits() {
        for width in stride(from: 700.0, through: 2000.0, by: 40) {
            let layout = PadLayout.resolve(window: CGSize(width: width, height: 800))
            guard let column = layout.detailWidth else { continue }
            let metrics = layout.metrics
            #expect(metrics.detail.contains(column))
            #expect(width - layout.railWidth - column >= metrics.boardColumnWidth)
        }
    }

    @Test("Closing the sidebar hands the tabs back to the bottom bar")
    func closedSidebar() {
        let open = PadLayout.resolve(window: CGSize(width: 1376, height: 1032), rail: 280)
        let closed = PadLayout.resolve(window: CGSize(width: 1376, height: 1032), rail: 280, closed: true)
        #expect(open.chrome == .rail)
        #expect(closed.chrome == .bottom)
        #expect(closed.railWidth == 0)
        #expect(!closed.showsDetail)
    }

    @Test("A landscape window too narrow for a column opens the post over the whole window")
    func noRoomForColumn() {
        let layout = PadLayout.resolve(window: CGSize(width: 760, height: 620))
        #expect(layout.chrome == .rail)
        #expect(!layout.showsDetail)
        #expect(layout.railWidth >= layout.metrics.narrowestRail)
    }

    @Test("The board adds a column as the window widens, and drops one as it narrows")
    func boardColumns() {
        #expect(MasonryLayout.columns(for: 320) == 1)
        #expect(MasonryLayout.columns(for: 640) == 2)
        #expect(MasonryLayout.columns(for: 1008) == 3)
        #expect(MasonryLayout.columns(for: 1280) == 4)
        #expect(MasonryLayout.columns(for: 3000) == MasonryLayout.maximumColumns)
    }

    @Test("An iPad sets two posts across in portrait and three in a wide landscape window")
    func boardFrames() {
        #expect(PadLayout.board(window: CGSize(width: 1032, height: 1376)).maximumColumns == 2)
        #expect(PadLayout.board(window: CGSize(width: 1376, height: 1032)).maximumColumns == 3)
        #expect(PadLayout.board(window: CGSize(width: 744, height: 1133)).maximumColumns == 2)
    }

    // MARK: - iPad mini

    @Test("A mini is measured as a mini, and a 13-inch window as a full-size iPad")
    func frames() {
        #expect(PadLayout.Frame.of(CGSize(width: 744, height: 1133)) == .mini)
        #expect(PadLayout.Frame.of(CGSize(width: 1133, height: 744)) == .mini)
        #expect(PadLayout.Frame.of(CGSize(width: 834, height: 1194)) == .regular)
        #expect(PadLayout.Frame.of(CGSize(width: 1032, height: 1376)) == .regular)
    }

    @Test("A mini's rail is narrower than a full-size iPad's, and never more than a mini can spare")
    func miniRail() {
        let mini = PadLayout.resolve(window: CGSize(width: 1133, height: 744))
        let regular = PadLayout.resolve(window: CGSize(width: 1376, height: 1032))
        #expect(mini.chrome == .rail)
        #expect(mini.railWidth < regular.railWidth)
        #expect(mini.railWidth == PadLayout.metrics(for: .mini).rail)
    }

    @Test("A mini opens a post beside the board, in a column of its own measure")
    func miniColumn() {
        let mini = PadLayout.resolve(window: CGSize(width: 1133, height: 744))
        let column = try? #require(mini.detailWidth)
        let metrics = PadLayout.metrics(for: .mini)
        #expect(metrics.detail.contains(column ?? 0))
        #expect(1133 - mini.railWidth - (column ?? 0) >= metrics.boardColumnWidth)
    }

    @Test("A mini never sets more than two posts side by side")
    func miniBoard() {
        for size in [CGSize(width: 744, height: 1133), CGSize(width: 1133, height: 744)] {
            let board = PadLayout.board(window: size)
            #expect(board.maximumColumns == 2)
            #expect(board.minimumColumnWidth == PadLayout.metrics(for: .mini).boardColumnWidth)
            #expect(MasonryLayout.columns(for: 728) <= board.maximumColumns)
        }
    }

    @Test("A mini's bar, clearance and rail all sit tighter than a full-size iPad's")
    func miniMetrics() {
        let mini = PadLayout.metrics(for: .mini)
        let regular = PadLayout.metrics(for: .regular)
        #expect(mini.rail < regular.rail)
        #expect(mini.barHeight < regular.barHeight)
        #expect(mini.barClearance < regular.barClearance)
        #expect(mini.barWidth < regular.barWidth)
        #expect(mini.detail.upperBound < regular.detail.upperBound)
    }

    @Test("Settings is the one tab with nowhere to put a second column")
    func detailColumnTabs() {
        #expect(TabItem.home.offersDetailColumn)
        #expect(TabItem.search.offersDetailColumn)
        #expect(TabItem.notifications.offersDetailColumn)
        #expect(!TabItem.settings.offersDetailColumn)
    }
}
