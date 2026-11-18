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
        #expect(layout.railWidth == PadLayout.railWidth)
        #expect(layout.showsDetail)
        let panel = try? #require(layout.detailWidth)
        #expect((panel ?? 0) >= 360 && (panel ?? 0) <= 560)
        #expect(1128 - (panel ?? 0) >= PadLayout.minimumBoardWidth)
    }

    @Test("A narrow rail is clamped to the range its grip allows")
    func narrowLandscape() {
        let layout = PadLayout.resolve(window: CGSize(width: 900, height: 700), rail: 80)
        #expect(layout.chrome == .rail)
        #expect(layout.railWidth == PadLayout.narrowestRailWidth)
        #expect(!layout.showsDetail)
    }

    @Test("A third of the screen is one column with the bar at the bottom")
    func narrowWindow() {
        let layout = PadLayout.resolve(window: CGSize(width: 620, height: 1000))
        #expect(layout.chrome == .bottom)
        #expect(layout.railWidth == 0)
        #expect(!layout.showsDetail)
        #expect(MasonryLayout.columns(for: 604) == 1)
    }

    @Test("Slide Over keeps the bottom bar whatever the height")
    func slideOver() {
        let layout = PadLayout.resolve(window: CGSize(width: 320, height: 900))
        #expect(layout.chrome == .bottom)
        #expect(!layout.showsDetail)
    }

    @Test("The panel keeps a reading measure and never eats the board")
    func wideWindow() {
        let window = CGSize(width: 2400, height: 1000)
        let layout = PadLayout.resolve(window: window)
        let panel = layout.detailWidth ?? 0
        #expect(panel <= 560)
        #expect(panel >= 360)
        #expect(window.width - layout.railWidth - panel > 800)
    }

    @Test("A panel opens beside a one-column board in a split window")
    func splitWindowPanel() {
        let layout = PadLayout.resolve(window: CGSize(width: 990, height: 744))
        #expect(layout.chrome == .rail)
        let panel = layout.detailWidth ?? 0
        #expect(panel >= PadLayout.minimumPanelWidth)
        #expect(990 - PadLayout.railWidth - panel >= PadLayout.minimumBoardWidth)
    }

    @Test("A panel beside the board always leaves it a column, never less")
    func panelFits() {
        for width in stride(from: 760.0, through: 2000.0, by: 80) {
            let layout = PadLayout.resolve(window: CGSize(width: width, height: 800))
            guard let panel = layout.detailWidth else { continue }
            #expect(panel <= 560)
            #expect(width - layout.railWidth - panel >= PadLayout.minimumBoardWidth)
            #expect(MasonryLayout.columns(for: width - layout.railWidth - panel) >= 1)
        }
    }

    @Test("A closed sidebar gives its room to the columns")
    func closedSidebar() {
        let open = PadLayout.resolve(window: CGSize(width: 1376, height: 1032), rail: 248)
        let closed = PadLayout.resolve(window: CGSize(width: 1376, height: 1032), rail: 248, closed: true)
        #expect(closed.railWidth == 0)
        #expect(closed.showsDetail)
        let openBoard = 1376 - 248 - (open.detailWidth ?? 0)
        let closedBoard = 1376 - (closed.detailWidth ?? 0)
        #expect(closedBoard > openBoard)
    }

    @Test("The board adds a column as the window widens, and drops one as it narrows")
    func boardColumns() {
        #expect(MasonryLayout.columns(for: 320) == 1)
        #expect(MasonryLayout.columns(for: 728) == 2)
        #expect(MasonryLayout.columns(for: 1008) == 3)
        #expect(MasonryLayout.columns(for: 1128) == 3)
        #expect(MasonryLayout.columns(for: 1240) == 4)
        #expect(MasonryLayout.columns(for: 3000) == MasonryLayout.maximumColumns)
    }

    @Test("Settings is the one tab with nowhere to put a second column")
    func detailColumnTabs() {
        #expect(TabItem.home.offersDetailColumn)
        #expect(TabItem.search.offersDetailColumn)
        #expect(TabItem.notifications.offersDetailColumn)
        #expect(!TabItem.settings.offersDetailColumn)
    }
}
