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
    }

    private func board(items: Int, width: CGFloat, counter: Counter,
                       anchor: Int? = nil) -> (MasonryLayout, UICollectionView) {
        let layout = MasonryLayout()
        layout.anchorOnFirstBuild(anchor)
        layout.numberOfItems = { items }
        layout.heightForItem = { indexPath in
            counter.measured.append(indexPath.item)
            counter.known[indexPath.item] = 240
            return 240
        }
        layout.knownHeightForItem = { counter.known[$0.item] }
        layout.estimatedHeightForItem = { _ in 200 }
        let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: width, height: 1000), collectionViewLayout: layout)
        return (layout, view)
    }

    @Test("A rebuild measures the posts on screen and stops a little past it")
    func measuresNearTheScreen() {
        let counter = Counter()
        let (layout, view) = board(items: 400, width: 760, counter: counter)
        layout.prepare()
        let onScreen = (0..<400).filter {
            (layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame.minY ?? .infinity) < 1000
        }
        #expect(Set(onScreen).isSubset(of: Set(counter.measured)))
        #expect(counter.measured.count <= MasonryLayout.measuredAhead + 1)
        #expect(view.collectionViewLayout.collectionViewContentSize.height > 1000)
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

    @Test("A board taking over from a list measures from the post the list had at the top")
    func anchorsOnTheListsTopPost() {
        let counter = Counter()
        let (layout, view) = board(items: 400, width: 760, counter: counter, anchor: 200)
        layout.prepare()
        #expect(Set(0...200).isSubset(of: Set(counter.measured)))
        #expect((counter.measured.max() ?? 0) <= 200 + MasonryLayout.measuredAhead)
        #expect(view.collectionViewLayout === layout)
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
}
