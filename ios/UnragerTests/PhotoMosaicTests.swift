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

    @Test("A lone 9:16 photo is shown whole, a taller one stops at 9:16")
    func tallPhotoStopsAtNineBySixteen() {
        #expect(abs(PhotoMosaic.make(ratios: [9.0 / 16.0], width: width).height - width * 16.0 / 9.0) < 0.01)
        #expect(abs(PhotoMosaic.make(ratios: [0.3], width: width).height - width * 16.0 / 9.0) < 0.01)
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
            #expect(PhotoMosaic.make(ratios: ratios, width: width).height <= width * 1.4)
        }
    }

    @Test("Media shape keeps a source's ratio inside the limits and clamps outside them")
    func mediaShape() {
        let wide: CGFloat = 16.0 / 9.0
        #expect(MediaShape.ratio(wide, fallback: 1) == wide)
        #expect(MediaShape.ratio(0.4, fallback: 1) == MediaShape.tallest)
        #expect(MediaShape.ratio(5, fallback: 1) == MediaShape.widest)
        #expect(MediaShape.ratio(nil, fallback: 1.25) == 1.25)
        #expect(MediaShape.ratio(0, fallback: 1.25) == 1.25)
    }
}
