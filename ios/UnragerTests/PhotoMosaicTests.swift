import CoreGraphics
import Testing
@testable import Unrager

@Suite("Photo mosaic and media shape")
struct PhotoMosaicTests {
    private let width: CGFloat = 390

    @Test("A lone landscape photo fills the width at its own ratio")
    func loneLandscape() {
        let mosaic = PhotoMosaic.make(ratios: [1.5], width: width)
        #expect(mosaic.tiles.count == 1)
        #expect(abs(mosaic.tiles[0].width - width) < 0.01)
        #expect(abs(mosaic.height - width / 1.5) < 0.01)
    }

    @Test("A lone tall photo's frame stops at 3:4, and a taller one is shown whole inside it")
    func tallPhotoStopsAtThreeByFour() {
        let phonePhoto = PhotoMosaic.make(ratios: [0.75], width: width)
        #expect(abs(phonePhoto.height - width / 0.75) < 0.01)
        #expect(MediaShape.frame(source: 0.75, fallback: 1).fills)
        for ratio: CGFloat in [2.0 / 3.0, 9.0 / 16.0, 0.3] {
            let mosaic = PhotoMosaic.make(ratios: [ratio], width: width)
            #expect(abs(mosaic.height - width / 0.75) < 0.01)
            #expect(!MediaShape.frame(source: ratio, fallback: 1).fills)
        }
    }

    @Test("A lone photo inside the limits fills a frame of its own shape")
    func ordinaryPhotosFill() {
        for ratio: CGFloat in [0.75, 0.8, 1.0, 4.0 / 3.0, 16.0 / 9.0, 2.4, 3.0] {
            let mosaic = PhotoMosaic.make(ratios: [ratio], width: width)
            #expect(MediaShape.frame(source: ratio, fallback: 1).fills)
            #expect(abs(mosaic.height - width / ratio) < 0.01)
        }
    }

    @Test("A panorama wider than 3:1 is shown whole in a 3:1 frame")
    func widePhotoStopsAtThreeToOne() {
        let frame = MediaShape.frame(source: 5, fallback: 1)
        #expect(frame.ratio == MediaShape.widest && !frame.fills)
        #expect(abs(PhotoMosaic.make(ratios: [5], width: width).height - width / 3) < 0.01)
    }

    @Test("Two landscape photos share one row, two portraits share one row")
    func pairsShareARow() {
        #expect(PhotoMosaic.rowSizes(for: [1.5, 1.5]) == [2])
        #expect(PhotoMosaic.rowSizes(for: [0.75, 0.75]) == [2])
        #expect(PhotoMosaic.rowSizes(for: [1.5, 0.75]) == [2])
    }

    @Test("Three landscape photos put one big over a pair")
    func threeLandscapes() {
        #expect(PhotoMosaic.rowSizes(for: [1.5, 1.5, 1.5]) == [1, 2])
    }

    @Test("Every row fills the width exactly and each tile keeps its photo's ratio")
    func rowsFillTheWidthAndKeepShape() {
        let ratios: [CGFloat] = [1.5, 0.75, 1.0, 1.78]
        let mosaic = PhotoMosaic.make(ratios: ratios, width: width)
        let rows = Dictionary(grouping: mosaic.tiles.enumerated(), by: { $0.element.minY })
        for (_, row) in rows {
            let last = row.max { $0.element.maxX < $1.element.maxX }!.element
            #expect(abs(last.maxX - width) < 0.01)
        }
        for (index, tile) in mosaic.tiles.enumerated() {
            #expect(abs(tile.width / tile.height - ratios[index]) < 0.001)
        }
    }

    @Test("Tiles stay inside the mosaic and never overlap")
    func tilesDoNotOverlap() {
        for ratios in [[1.5, 1.5, 1.5, 1.5], [0.6, 0.6, 0.6, 0.6], [2.0, 0.7, 1.0], [1.0, 1.0]] as [[CGFloat]] {
            let mosaic = PhotoMosaic.make(ratios: ratios, width: width)
            let bounds = CGRect(x: -0.01, y: -0.01, width: width + 0.02, height: mosaic.height + 0.02)
            for tile in mosaic.tiles { #expect(bounds.contains(tile)) }
            for (i, a) in mosaic.tiles.enumerated() {
                for b in mosaic.tiles[(i + 1)...] { #expect(!a.insetBy(dx: 0.01, dy: 0.01).intersects(b)) }
            }
            #expect(abs((mosaic.tiles.map(\.maxY).max() ?? 0) - mosaic.height) < 0.01)
        }
    }

    @Test("More than four photos lay out four, an unknown shape counts as 4:3")
    func capsAtFourAndFallsBack() {
        #expect(PhotoMosaic.make(ratios: Array(repeating: 1.0, count: 7), width: width).tiles.count == 4)
        let unknown = PhotoMosaic.make(ratios: [nil], width: width)
        #expect(abs(unknown.height - width * 3 / 4) < 0.01)
    }

    @Test("A group of photos never runs past a screenful")
    func groupsStayCompact() {
        for ratios in [[0.6, 0.6], [0.6, 0.6, 0.6, 0.6], [1.0, 1.0, 1.0, 1.0]] as [[CGFloat]] {
            #expect(PhotoMosaic.make(ratios: ratios, width: width).height <= width * 1.05)
        }
    }

    @Test("A clip's frame follows its shape within 3:4 and 3:1 and shows it whole beyond")
    func videoFrames() {
        let sixteenByNine = MediaShape.frame(source: 16.0 / 9.0, fallback: 1)
        #expect(sixteenByNine.fills && abs(sixteenByNine.ratio - 16.0 / 9.0) < 0.0001)
        let vertical = MediaShape.frame(source: 9.0 / 16.0, fallback: 1)
        #expect(vertical.ratio == MediaShape.tallest && !vertical.fills)
        let square = MediaShape.frame(source: 1.0, fallback: 16.0 / 9.0)
        #expect(square.ratio == 1.0 && square.fills)
        let nearlyThreeByFour = MediaShape.frame(source: 0.74, fallback: 1)
        #expect(nearlyThreeByFour.ratio == MediaShape.tallest && nearlyThreeByFour.fills)
        let unknown = MediaShape.frame(source: nil, fallback: 16.0 / 9.0)
        #expect(!unknown.fills && abs(unknown.ratio - 16.0 / 9.0) < 0.0001)
    }

    @Test("Media shape keeps a tile's ratio inside the group limits and clamps outside them")
    func mediaShape() {
        let wide: CGFloat = 16.0 / 9.0
        #expect(MediaShape.ratio(wide, fallback: 1) == wide)
        #expect(MediaShape.ratio(0.4, fallback: 1) == MediaShape.tallestInGroup)
        #expect(MediaShape.ratio(5, fallback: 1) == MediaShape.widestInGroup)
        #expect(MediaShape.ratio(nil, fallback: 1.25) == 1.25)
        #expect(MediaShape.ratio(0, fallback: 1.25) == 1.25)
    }

    @Test("A picture fills a box only when it is the box's shape, to within what the eye can't see")
    func matchesIsTight() {
        let box = CGSize(width: 390, height: 520)
        #expect(MediaShape.matches(CGSize(width: 1200, height: 1600), in: box))
        #expect(MediaShape.matches(CGSize(width: 1195, height: 1600), in: box))
        #expect(!MediaShape.matches(CGSize(width: 1000, height: 1500), in: box))
        #expect(!MediaShape.matches(CGSize(width: 1600, height: 1200), in: box))
        #expect(!MediaShape.matches(.zero, in: box))
        #expect(MediaShape.mismatch(1, 1) == 0)
        #expect(abs(MediaShape.mismatch(0.5, 1) - 0.5) < 0.0001)
    }

    @Test("A tile photo beyond the group limits keeps a tile of the nearest limit")
    func extremePhotoInAGroup() {
        let mosaic = PhotoMosaic.make(ratios: [0.3, 0.3], width: width)
        for tile in mosaic.tiles {
            #expect(abs(tile.width / tile.height - MediaShape.tallestInGroup) < 0.001)
        }
    }
}
