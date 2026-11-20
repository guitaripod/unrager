import Foundation
import Testing
import UIKit
@testable import Unrager

@MainActor
@Suite("Board layout")
struct MasonryLayoutTests {
    private final class Counter {
        var measured: [Int] = []
        var known: [Int: CGFloat] = [:]
        var height: (Int) -> CGFloat = { _ in 240 }
    }

    private func board(items: Int, width: CGFloat, counter: Counter,
                       anchor: Int? = nil, estimate: CGFloat = 200) -> (MasonryLayout, UICollectionView) {
        let layout = MasonryLayout()
        layout.anchorOnFirstBuild(anchor)
        layout.numberOfItems = { items }
        layout.heightForItem = { indexPath in
            counter.measured.append(indexPath.item)
            let height = counter.height(indexPath.item)
            counter.known[indexPath.item] = height
            return height
        }
        layout.knownHeightForItem = { counter.known[$0.item] }
        layout.estimatedHeightForItem = { _ in estimate }
        let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: width, height: 1000), collectionViewLayout: layout)
        return (layout, view)
    }

    /// A layout holds its collection view weakly, so a test keeps the view it
    /// was handed alive until the layout has answered.
    private func frame(_ item: Int, in layout: MasonryLayout) -> CGRect {
        layout.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame ?? .null
    }

    @Test("A rebuild measures the posts on screen and stops a little past it")
    func measuresNearTheScreen() {
        let counter = Counter()
        let (layout, view) = board(items: 400, width: 760, counter: counter)
        layout.prepare()
        let onScreen = (0..<400).filter { frame($0, in: layout).minY < 1000 }
        #expect(Set(onScreen).isSubset(of: Set(counter.measured)))
        #expect(counter.measured.allSatisfy { frame($0, in: layout).minY < 1250 })
        #expect(view.collectionViewLayout.collectionViewContentSize.height > 1000)
    }

    @Test("Every post on screen is measured before the frame, however many short ones fit")
    func measuresEveryShortPostOnScreen() {
        let counter = Counter()
        counter.height = { _ in 60 }
        let (layout, view) = board(items: 400, width: 760, counter: counter)
        layout.prepare()
        let onScreen = (0..<400).filter { frame($0, in: layout).minY < 1000 }
        #expect(onScreen.count > 20)
        #expect(Set(onScreen).isSubset(of: Set(counter.measured)))
        #expect(onScreen.allSatisfy { frame($0, in: layout).height == 60 })
        withExtendedLifetime(view) {}
    }

    @Test("Posts below the screen are measured once the frame is up")
    func measuresTheRestAfterTheFrame() async throws {
        let counter = Counter()
        let (layout, view) = board(items: 120, width: 760, counter: counter)
        layout.prepare()
        try await Task.sleep(for: .milliseconds(400))
        #expect(Set(counter.measured).count == 120)
        layout.prepare()
        let last = view.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 119, section: 0))
        #expect(last?.frame.height == 240)
    }

    @Test("A board opened deep down measures a screenful, not every post above the reader")
    func deepOpeningMeasuresAScreenful() {
        let counter = Counter()
        let (layout, view) = board(items: 400, width: 760, counter: counter, anchor: 300)
        layout.prepare()
        #expect(layout.seam == 300)
        #expect(counter.measured.allSatisfy { $0 >= 290 })
        #expect(counter.measured.count < 30)
        #expect(counter.measured.contains(300))
        withExtendedLifetime(view) {}
    }

    @Test("The reader's post opens the seam, flush across the columns")
    func seamOpensOnTheReadersPost() {
        let counter = Counter()
        let (layout, view) = board(items: 400, width: 760, counter: counter, anchor: 300)
        layout.prepare()
        let seamLine = frame(300, in: layout).minY
        #expect(frame(301, in: layout).minY == seamLine)
        #expect(frame(299, in: layout).maxY + layout.itemSpacing == seamLine)
        #expect(frame(298, in: layout).maxY + layout.itemSpacing == seamLine)
        #expect((0..<300).allSatisfy { frame($0, in: layout).maxY <= seamLine })
        #expect((0..<300).map { frame($0, in: layout).minY }.min() == layout.sectionInset.top)
        withExtendedLifetime(view) {}
    }

    @Test("Posts above the seam settling to their real heights never move the posts below it")
    func refiningAboveNeverRearrangesBelow() async throws {
        let counter = Counter()
        let (layout, view) = board(items: 400, width: 760, counter: counter, anchor: 300)
        layout.prepare()
        let line = frame(300, in: layout).minY
        let onScreen = (300..<400).filter { frame($0, in: layout).minY < line + 1000 }
        let before = onScreen.map { frame($0, in: layout).offsetBy(dx: 0, dy: -line) }
        try await Task.sleep(for: .milliseconds(1500))
        #expect(Set(counter.measured).count == 400)
        layout.prepare()
        let settled = frame(300, in: layout).minY
        #expect(settled > line)
        let after = onScreen.map { frame($0, in: layout).offsetBy(dx: 0, dy: -settled) }
        #expect(onScreen.count >= 6)
        #expect(before == after)
        withExtendedLifetime(view) {}
    }

    @Test("A width every post above the reader is known at lays out top-down as before")
    func knownWidthLaysOutTopDown() {
        let counter = Counter()
        for item in 0..<300 { counter.known[item] = 240 }
        let (layout, view) = board(items: 400, width: 760, counter: counter, anchor: 300)
        layout.prepare()
        #expect(layout.seam == 0)
        #expect(frame(0, in: layout).minY == layout.sectionInset.top)
        #expect(frame(1, in: layout).minY == layout.sectionInset.top)
        withExtendedLifetime(view) {}
    }

    @Test("A board the list replaces measures nothing at its new width")
    func retiredBoardMeasuresNothing() {
        let counter = Counter()
        let (layout, view) = board(items: 400, width: 760, counter: counter)
        layout.retire()
        view.frame.size.width = 360
        layout.invalidateLayout()
        layout.prepare()
        #expect(counter.measured.isEmpty)
    }

    @Test("A board opened deep down starts every column at its top, however uneven the posts above")
    func deepOpeningLevelsTheTop() {
        let counter = Counter()
        counter.height = { item in [140, 420, 260, 610, 180, 330, 90, 500][item % 8] }
        let (layout, view) = board(items: 400, width: 1100, counter: counter, anchor: 300, estimate: 260)
        layout.prepare()
        #expect(layout.seam == 300)
        let frames = (0..<300).map { frame($0, in: layout) }
        let columns = Dictionary(grouping: frames, by: { $0.minX })
        #expect(columns.count == 3)
        for (_, stack) in columns {
            #expect(stack.map(\.minY).min() == layout.sectionInset.top)
            #expect((stack.map(\.maxY).max() ?? 0) + layout.itemSpacing == frame(300, in: layout).minY)
        }
        withExtendedLifetime(view) {}
    }

    @Test("A reader near the top is laid out top-down, every post above measured")
    func shallowOpeningStaysTopDown() {
        let counter = Counter()
        let (layout, view) = board(items: 400, width: 760, counter: counter, anchor: 30)
        layout.prepare()
        #expect(layout.seam == 0)
        #expect(Set(0...30).isSubset(of: Set(counter.measured)))
        #expect(frame(0, in: layout).minY == layout.sectionInset.top)
        withExtendedLifetime(view) {}
    }

    @Test("The topmost posts above a seam are placed to level the columns")
    func stacksLevelTheirTops() {
        let heights: [CGFloat] = (0..<120).map { [140, 420, 260, 610, 180, 330, 90, 500][$0 % 8] }
        let stacks = MasonryLayout.stacks(above: heights, columns: 3, spacing: 10)
        #expect(stacks.flatMap(\.items).sorted() == Array(0..<120))
        let spread = (stacks.map(\.height).max() ?? 0) - (stacks.map(\.height).min() ?? 0)
        #expect(spread <= 60)
    }
}
