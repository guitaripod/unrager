import CoreGraphics
import Foundation

/// How tall or wide an attachment may be drawn before it is cropped. Most media
/// sits well inside these limits and is shown whole; only a panorama wider than
/// 2.4:1 or a column taller than 9:16 loses a sliver.
enum MediaShape {
    static let tallest: CGFloat = 9.0 / 16.0
    static let widest: CGFloat = 2.4

    /// The width ÷ height to draw a source at: its own when it has one within
    /// the limits, the nearest limit when it doesn't, `fallback` when unknown.
    static func ratio(_ source: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let source, source > 0 else { return fallback }
        return min(max(source, tallest), widest)
    }
}

/// A justified layout for up to four photos: they sit in rows, and each row is
/// as tall as it must be for every photo in it to keep its own shape, so none
/// is cropped and none is letterboxed. Two landscape shots share a short row,
/// two portraits a tall one, a landscape and a portrait meet at the same
/// height. Which photos share a row is whichever split lands the rows nearest a
/// comfortable height without making the whole post a screenful.
struct PhotoMosaic: Equatable {
    static let gutter: CGFloat = 2
    static let maxPhotos = 4

    private static let comfortableRow: CGFloat = 0.5
    private static let tallestGroup: CGFloat = 1.3

    let tiles: [CGRect]
    let height: CGFloat

    /// Lays out `ratios` (width ÷ height per photo, nil when unknown) across
    /// `width`; photos past the fourth are ignored.
    static func make(ratios: [CGFloat?], width: CGFloat) -> PhotoMosaic {
        let shapes = ratios.prefix(maxPhotos).map { MediaShape.ratio($0, fallback: 4.0 / 3.0) }
        guard !shapes.isEmpty, width > 0 else { return PhotoMosaic(tiles: [], height: 0) }
        let rows = bestRows(for: shapes, width: width)
        return frames(for: rows, shapes: shapes, width: width)
    }

    /// How many photos go in each row, in order.
    static func rowSizes(for ratios: [CGFloat?], width: CGFloat = 390) -> [Int] {
        let shapes = ratios.prefix(maxPhotos).map { MediaShape.ratio($0, fallback: 4.0 / 3.0) }
        return shapes.isEmpty ? [] : bestRows(for: shapes, width: width)
    }

    private static func bestRows(for shapes: [CGFloat], width: CGFloat) -> [Int] {
        var best: (rows: [Int], score: CGFloat)?
        for rows in splits(of: shapes.count) {
            let score = score(rows, shapes: shapes, width: width)
            if best == nil || score < best!.score - 1e-9 { best = (rows, score) }
        }
        return best?.rows ?? [shapes.count]
    }

    /// Every way to cut `count` photos, in order, into consecutive rows.
    private static func splits(of count: Int) -> [[Int]] {
        guard count > 1 else { return [[count]] }
        var result: [[Int]] = []
        for first in 1...count {
            if first == count { result.append([count]); continue }
            for rest in splits(of: count - first) { result.append([first] + rest) }
        }
        return result
    }

    private static func rowHeight(_ photos: ArraySlice<CGFloat>, width: CGFloat) -> CGFloat {
        (width - gutter * CGFloat(photos.count - 1)) / photos.reduce(0, +)
    }

    /// Lower is better: rows near the comfortable height, and a penalty when a
    /// group of several photos would run taller than a screenful.
    private static func score(_ rows: [Int], shapes: [CGFloat], width: CGFloat) -> CGFloat {
        var start = 0
        var total = gutter * CGFloat(rows.count - 1)
        var score: CGFloat = 0
        for count in rows {
            let height = rowHeight(shapes[start..<start + count], width: width)
            score += abs(log(height / (width * comfortableRow)))
            total += height
            start += count
        }
        if shapes.count > 1, total > width * tallestGroup {
            score += 3 * log(total / (width * tallestGroup))
        }
        return score
    }

    private static func frames(for rows: [Int], shapes: [CGFloat], width: CGFloat) -> PhotoMosaic {
        var tiles: [CGRect] = []
        var y: CGFloat = 0
        var start = 0
        for count in rows {
            let slice = shapes[start..<start + count]
            let height = rowHeight(slice, width: width)
            var x: CGFloat = 0
            for shape in slice {
                let tileWidth = shape * height
                tiles.append(CGRect(x: x, y: y, width: tileWidth, height: height))
                x += tileWidth + gutter
            }
            y += height + gutter
            start += count
        }
        return PhotoMosaic(tiles: tiles, height: y - gutter)
    }
}
