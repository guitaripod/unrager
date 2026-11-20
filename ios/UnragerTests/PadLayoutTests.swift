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
    }

    @Test("A wide window puts the tabs on the side, with the board beside them")
    func landscape() {
        let layout = PadLayout.resolve(window: CGSize(width: 1376, height: 1032))
        #expect(layout.chrome == .rail)
        #expect(layout.railWidth == PadLayout.metrics(for: .regular).rail)
        #expect(1376 - layout.railWidth >= PadLayout.twoColumnBoard(layout.metrics))
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
        #expect(MasonryLayout.columns(for: 604) == 1)
        #expect(PadLayout.board(window: CGSize(width: 620, height: 1000)).maximumColumns == 2)
    }

    @Test("Slide Over keeps the bottom bar whatever the height")
    func slideOver() {
        let layout = PadLayout.resolve(window: CGSize(width: 320, height: 900))
        #expect(layout.chrome == .bottom)
    }

    @Test("Closing the sidebar hands the tabs back to the bottom bar")
    func closedSidebar() {
        let open = PadLayout.resolve(window: CGSize(width: 1376, height: 1032), rail: 280)
        let closed = PadLayout.resolve(window: CGSize(width: 1376, height: 1032), rail: 280, closed: true)
        #expect(open.chrome == .rail)
        #expect(closed.chrome == .bottom)
        #expect(closed.railWidth == 0)
    }

    @Test("A rail only where the feed keeps two posts across beside it")
    func railNeedsRoom() {
        #expect(!PadLayout.allowsRail(window: CGSize(width: 834, height: 600)))
        #expect(!PadLayout.allowsRail(window: CGSize(width: 800, height: 834)))
        #expect(!PadLayout.allowsRail(window: CGSize(width: 880, height: 700)))
        #expect(PadLayout.allowsRail(window: CGSize(width: 1194, height: 834)))
        #expect(PadLayout.allowsRail(window: CGSize(width: 1133, height: 744)))
        #expect(PadLayout.allowsRail(window: CGSize(width: 917, height: 1032)) == false)
        let short = PadLayout.resolve(window: CGSize(width: 834, height: 600), screen: CGSize(width: 834, height: 1194))
        #expect(short.chrome == .bottom)
        #expect(PadLayout.board(window: CGSize(width: 834, height: 600)).maximumColumns == 2)
    }

    @Test("What kind of iPad it is comes from the screen, never the window")
    func frameFromScreen() {
        let shortOnBig = PadLayout.resolve(window: CGSize(width: 1032, height: 600),
                                           screen: CGSize(width: 1376, height: 1032))
        #expect(shortOnBig.frame == .regular)
        let miniWindow = PadLayout.resolve(window: CGSize(width: 1133, height: 744),
                                           screen: CGSize(width: 1133, height: 744))
        #expect(miniWindow.frame == .mini)
        #expect(PadLayout.board(window: CGSize(width: 1032, height: 600),
                                screen: CGSize(width: 1376, height: 1032)).dense == false)
    }

    @Test("Every width from Slide Over to a 13-inch screen keeps the content area positive")
    func everyWidthLeavesContent() {
        for width in stride(from: 320.0, through: 1376.0, by: 2) {
            for height in [600.0, 744, 834, 1032, 1194] {
                let layout = PadLayout.resolve(window: CGSize(width: width, height: height),
                                               screen: CGSize(width: 1194, height: 834))
                let content = width - layout.railWidth
                #expect(content >= 320)
                if layout.chrome == .rail { #expect(width >= PadLayout.railWindowMinimum) }
            }
        }
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
    }

    @Test("Settings is the one tab whose list stays a column of forms")
    func boardTabs() {
        #expect(TabItem.home.offersBoard)
        #expect(TabItem.search.offersBoard)
        #expect(TabItem.notifications.offersBoard)
        #expect(!TabItem.settings.offersBoard)
    }

    @Test("A window that only grows taller can turn the board from three columns to two at the same width")
    func heightAloneTurnsTheBoard() {
        let screen = CGSize(width: 1366, height: 1024)
        let wide = PadLayout.board(window: CGSize(width: 900, height: 850), screen: screen)
        let tall = PadLayout.board(window: CGSize(width: 900, height: 1000), screen: screen)
        #expect(wide != tall)
        #expect(tall.maximumColumns == 2)
        #expect(wide.maximumColumns > tall.maximumColumns)
        let board = CGFloat(900 - 20)
        #expect(min(board, wide.maximumWidth) == min(board, tall.maximumWidth))
    }
}
