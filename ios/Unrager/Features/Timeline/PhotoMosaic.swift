import CoreGraphics
import Foundation

/// How tall or wide an attachment may be drawn. A lone photo or clip is shown
/// at its own shape until it would be taller than `tallestPhoto` (4:5) or
/// `tallestVideo` (square): past that the frame stops growing, so a vertical
/// video never takes over the screen. What doesn't fit that frame is cropped
/// when the loss is slight and otherwise shown whole over a blurred copy of
/// itself, never over black bars.
enum MediaShape {
    static let widest: CGFloat = 2.4
    static let tallestPhoto: CGFloat = 0.8
    static let tallestVideo: CGFloat = 1.0
    /// The most a picture may lose at its edges before it is shown whole.
    static let cropTolerance: CGFloat = 0.12
    /// The narrowest a photo may be inside a group (9:16): tiles that share a
    /// row are cropped a little rather than letting one tile set the height.
    static let tallest: CGFloat = 9.0 / 16.0

    /// A lone attachment's frame: its width ÷ height, and whether the picture
    /// fills it (a slight crop at most) or is shown whole over a soft backdrop.
    struct Frame: Equatable {
        var ratio: CGFloat
        var fills: Bool
    }

    static func frame(source: CGFloat?, tallest limit: CGFloat, fallback: CGFloat) -> Frame {
        guard let source, source > 0 else { return Frame(ratio: min(max(fallback, limit), widest), fills: true) }
        let ratio = min(max(source, limit), widest)
        let kept = source < ratio ? source / ratio : ratio / source
        return Frame(ratio: ratio, fills: 1 - kept <= cropTolerance)
    }

    /// The width ÷ height to draw a tile in a group at: its own when it has one
    /// within the limits, the nearest limit when it doesn't, `fallback` when
    /// unknown.
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
    private static let tallestGroup: CGFloat = 1.0

    let tiles: [CGRect]
    let height: CGFloat
    /// A lone photo that is shown whole inside a frame of another shape, so it
    /// sits over a soft backdrop of itself.
    var letterboxed = false

    /// Lays out `ratios` (width ÷ height per photo, nil when unknown) across
    /// `width`; photos past the fourth are ignored.
    static func make(ratios: [CGFloat?], width: CGFloat) -> PhotoMosaic {
        guard !ratios.isEmpty, width > 0 else { return PhotoMosaic(tiles: [], height: 0) }
        if ratios.count == 1 {
            let frame = MediaShape.frame(source: ratios[0], tallest: MediaShape.tallestPhoto, fallback: 4.0 / 3.0)
            let height = width / frame.ratio
            return PhotoMosaic(tiles: [CGRect(x: 0, y: 0, width: width, height: height)], height: height,
                               letterboxed: !frame.fills)
        }
        let shapes = ratios.prefix(maxPhotos).map { MediaShape.ratio($0, fallback: 4.0 / 3.0) }
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
