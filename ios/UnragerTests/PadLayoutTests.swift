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
        #expect(layout.primaryWidth == nil)
    }

    @Test("A wide window puts the tabs on the side, with a column beside the feed")
    func landscape() {
        let layout = PadLayout.resolve(window: CGSize(width: 1376, height: 1032))
        #expect(layout.chrome == .rail)
        #expect(layout.railWidth == PadLayout.railWidth)
        #expect(layout.showsDetail)
        #expect(layout.primaryWidth == 552)
        #expect(layout.detailWidth == 552)
    }

    @Test("A narrow rail is clamped to the range its grip allows")
    func narrowLandscape() {
        let layout = PadLayout.resolve(window: CGSize(width: 900, height: 700), rail: 80)
        #expect(layout.chrome == .rail)
        #expect(layout.railWidth == PadLayout.narrowestRailWidth)
        #expect(!layout.showsDetail)
    }

    @Test("Slide Over keeps the bottom bar whatever the height")
    func slideOver() {
        let layout = PadLayout.resolve(window: CGSize(width: 320, height: 900))
        #expect(layout.chrome == .bottom)
        #expect(!layout.showsDetail)
    }

    @Test("Two columns never grow past a readable measure, and keep their gutter")
    func wideWindow() {
        let window = CGSize(width: 2400, height: 1000)
        let layout = PadLayout.resolve(window: window)
        #expect(layout.primaryWidth == DesignSystem.maxContentWidth)
        #expect(layout.detailWidth == DesignSystem.maxContentWidth)
        let used = layout.railWidth + 2 * DesignSystem.maxContentWidth + PadLayout.columnGap
        #expect(window.width - used > 0)
    }

    @Test("Both columns are the same width and fit beside the rail")
    func columnsFit() {
        var twoColumnWidths = 0
        for width in stride(from: 1000.0, through: 2000.0, by: 100) {
            let layout = PadLayout.resolve(window: CGSize(width: width, height: 800))
            guard let primary = layout.primaryWidth, let detail = layout.detailWidth else {
                #expect(width - layout.railWidth < PadLayout.twoColumnMinimum)
                continue
            }
            twoColumnWidths += 1
            #expect(primary == detail)
            #expect(layout.railWidth + primary + PadLayout.columnGap + detail <= width)
        }
        #expect(twoColumnWidths > 0)
    }

    @Test("A closed sidebar gives its room to the columns")
    func closedSidebar() {
        let open = PadLayout.resolve(window: CGSize(width: 1376, height: 1032), rail: 248)
        let closed = PadLayout.resolve(window: CGSize(width: 1376, height: 1032), rail: 248, closed: true)
        #expect(closed.railWidth == 0)
        #expect(closed.showsDetail)
        #expect(closed.primaryWidth! > open.primaryWidth!)
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
