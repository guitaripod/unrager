import Foundation
import Testing
import UIKit
@testable import Unrager

@Suite("Pad reach")
struct PadReachTests {
    private let landscape = CGRect(x: 0, y: 0, width: 1194, height: 834)
    private let portrait = CGRect(x: 0, y: 0, width: 834, height: 1194)

    @Test("A full-screen window touches both edges, so nothing hugs a side")
    func fullScreen() {
        let reach = PadReach.resolve(window: landscape, screen: landscape, rightToLeft: false)
        #expect(reach.heldSideways)
        #expect(reach.outerEdge == nil)
        #expect(!reach.hugsSide)
        #expect(reach.primarySide == .trailing)
        #expect(reach.railInReach)
    }

    @Test("A window against one edge of a landscape screen hugs that edge")
    func sharedScreen() {
        let left = PadReach.resolve(window: CGRect(x: 0, y: 0, width: 600, height: 834),
                                    screen: landscape, rightToLeft: false)
        #expect(left.outerEdge == .leading)
        #expect(left.hugsSide)
        #expect(left.primarySide == .leading)
        #expect(left.railInReach)
        let right = PadReach.resolve(window: CGRect(x: 820, y: 0, width: 374, height: 834),
                                     screen: landscape, rightToLeft: false)
        #expect(right.outerEdge == .trailing)
        #expect(right.primarySide == .trailing)
        #expect(!right.railInReach)
    }

    @Test("A floating window, or a portrait iPad, keeps the usual places")
    func noHug() {
        let floating = PadReach.resolve(window: CGRect(x: 300, y: 40, width: 500, height: 600),
                                        screen: landscape, rightToLeft: false)
        #expect(floating.outerEdge == nil)
        #expect(!floating.hugsSide)
        let tall = PadReach.resolve(window: CGRect(x: 0, y: 0, width: 412, height: 1194),
                                    screen: portrait, rightToLeft: false)
        #expect(!tall.heldSideways)
        #expect(tall.outerEdge == .leading)
        #expect(!tall.hugsSide)
        #expect(tall.primarySide == .trailing)
        #expect(tall.railInReach)
    }

    @Test("Right to left, the screen's left edge is the trailing one")
    func rightToLeft() {
        let reach = PadReach.resolve(window: CGRect(x: 0, y: 0, width: 600, height: 834),
                                     screen: landscape, rightToLeft: true)
        #expect(reach.outerEdge == .trailing)
        #expect(reach.primarySide == .trailing)
    }

    @Test("A third of the screen stacks compose above a bar that takes the width")
    func thirdOfScreenDock() {
        let reach = PadReach(heldSideways: true, outerEdge: .trailing)
        let dock = reach.dock(width: 375, tabs: 4, itemWidth: 86, maximumBar: 560, button: 62)
        #expect(dock.placement == .hugging(.trailing))
        #expect(!dock.composeBesideBar)
        #expect(dock.barWidth == 375 - PadReach.dockMargin * 2)
        #expect(dock.composeSide == .trailing)
    }

    @Test("Half the screen puts compose beside the bar, outermost")
    func halfScreenDock() {
        let reach = PadReach(heldSideways: true, outerEdge: .leading)
        let dock = reach.dock(width: 600, tabs: 4, itemWidth: 86, maximumBar: 560, button: 62)
        #expect(dock.placement == .hugging(.leading))
        #expect(dock.composeBesideBar)
        #expect(abs(dock.barWidth - 356) < 0.5)
        #expect(dock.composeSide == .leading)
    }

    @Test("A portrait window centres the bar with compose level in the corner")
    func portraitDock() {
        let dock = PadReach.standard.dock(width: 834, tabs: 5, itemWidth: 86, maximumBar: 560, button: 62)
        #expect(dock.placement == .centred)
        #expect(dock.composeBesideBar)
        #expect(dock.composeSide == .trailing)
        let narrow = PadReach.standard.dock(width: 375, tabs: 5, itemWidth: 86, maximumBar: 560, button: 62)
        #expect(!narrow.composeBesideBar)
        #expect(narrow.barWidth <= 375 - PadReach.dockMargin * 2)
    }

    @Test("The dock never runs past the window at any width")
    func dockFits() {
        for width in stride(from: 320.0, through: 1376.0, by: 4) {
            for reach in [PadReach.standard, PadReach(heldSideways: true, outerEdge: .leading),
                          PadReach(heldSideways: true, outerEdge: .trailing)] {
                for tabs in 2...5 {
                    let dock = reach.dock(width: width, tabs: tabs, itemWidth: 86, maximumBar: 560, button: 62)
                    let used = dock.barWidth + (dock.composeBesideBar ? PadReach.dockGap + 62 : 0)
                    #expect(used <= width - PadReach.dockMargin * 2 + 0.5)
                    if dock.placement == .centred, dock.composeBesideBar {
                        #expect((width - dock.barWidth) / 2 - PadReach.dockMargin >= 62 + PadReach.dockGap)
                    }
                }
            }
        }
    }
}
