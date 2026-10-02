import CoreGraphics
import Foundation

/// How an attachment is framed, and when a picture is drawn whole. Nothing is
/// ever cropped to fit: a lone photo or clip gets a frame of its own shape,
/// within `tallest` (3:4, a phone photo) and `widest` (3:1, a panorama), and a
/// picture past those limits, or one whose real shape isn't what the server
/// said, is shown whole inside the frame over a soft backdrop of itself, never
/// over black bars. Only a mismatch too small to see (`cropTolerance`) is let
/// fill the frame, so no sliver of backdrop shows at an edge.
enum MediaShape {
    static let widest: CGFloat = 3.0
    static let tallest: CGFloat = 0.75
    /// The most a picture may be stretched past its frame's shape before the
    /// backdrop shows: 1.5% is about 6 pt of a full-width photo.
    static let cropTolerance: CGFloat = 0.015
    /// The narrowest (9:16) and widest (12:5) a photo may be inside a group:
    /// tiles that share a row take a shape within these so one extreme photo
    /// can't set the height of the row, and a photo beyond them is shown whole
    /// inside its tile.
    static let tallestInGroup: CGFloat = 9.0 / 16.0
    static let widestInGroup: CGFloat = 2.4

    /// The shape of a link card's large cover image (1.91:1).
    static let largeCover: CGFloat = 1.91
    /// The shape of a video thumbnail (16:9), for YouTube and broadcasts.
    static let videoCover: CGFloat = 16.0 / 9.0

    /// A lone attachment's frame: its width ÷ height, and whether the picture
    /// is the frame's shape (so it fills it) or is shown whole over a backdrop.
    struct Frame: Equatable {
        var ratio: CGFloat
        var fills: Bool
    }

    /// The frame for a lone picture of shape `source` (nil when unknown, which
    /// draws `fallback` and shows the picture whole once it is known to differ).
    static func frame(source: CGFloat?, fallback: CGFloat) -> Frame {
        guard let source, source > 0 else {
            return Frame(ratio: min(max(fallback, tallest), widest), fills: false)
        }
        let ratio = min(max(source, tallest), widest)
        return Frame(ratio: ratio, fills: mismatch(source, ratio) <= cropTolerance)
    }

    /// The width ÷ height to draw a tile in a group at: its own when it has one
    /// within the limits, the nearest limit when it doesn't, `fallback` when
    /// unknown.
    static func ratio(_ source: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let source, source > 0 else { return fallback }
        return min(max(source, tallestInGroup), widestInGroup)
    }

    /// How far apart two shapes are, 0 for the same and approaching 1 for
    /// extremes: the share of the larger ratio the smaller one lacks.
    static func mismatch(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        guard a > 0, b > 0 else { return 1 }
        return 1 - min(a, b) / max(a, b)
    }

    /// Whether a picture of this size is the shape of `box`, so it can fill it.
    static func matches(_ image: CGSize, in box: CGSize) -> Bool {
        guard image.height > 0, box.height > 0 else { return false }
        return mismatch(image.width / image.height, box.width / box.height) <= cropTolerance
    }
}

/// A justified layout for up to four photos: they sit in rows, and each row is
/// as tall as it must be for every photo in it to keep its own shape, so none
/// is cropped and none needs a backdrop. Two landscape shots share a short row,
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

    /// Lays out `ratios` (width ÷ height per photo, nil when unknown) across
    /// `width`; photos past the fourth are ignored.
    static func make(ratios: [CGFloat?], width: CGFloat) -> PhotoMosaic {
        guard !ratios.isEmpty, width > 0 else { return PhotoMosaic(tiles: [], height: 0) }
        if ratios.count == 1 {
            let frame = MediaShape.frame(source: ratios[0], fallback: 4.0 / 3.0)
            let height = width / frame.ratio
            return PhotoMosaic(tiles: [CGRect(x: 0, y: 0, width: width, height: height)], height: height)
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
