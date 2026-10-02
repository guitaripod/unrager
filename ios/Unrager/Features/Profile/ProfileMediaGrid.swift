import CoreGraphics
import Foundation
import UnragerKit

/// What the Media tab of a profile shows and how it is laid out: every photo
/// and clip from the account's own posts, in rows that run edge to edge, each
/// picture at its own shape so none is cropped. Rows are justified: pictures
/// are added until a row, scaled to the full width, comes down to the target
/// height, so a row of panoramas is short and a row of portraits tall.
enum ProfileMediaGrid {
    static let gutter: CGFloat = 2
    static let targetHeight: CGFloat = 132
    static let maxPerRow = 4
    /// How much taller than the target a short last row may stretch to fill the
    /// width, as a multiple of the target; past it the row keeps the target height.
    static let lastRowStretchLimit: CGFloat = 2.0

    /// One picture or clip poster in the grid, and the post it came from.
    struct Item: Hashable {
        let id: String
        let tweetID: String
        let mediaIndex: Int
        let url: URL
        let isVideo: Bool
        let ratio: CGFloat?
        let hasAlt: Bool
    }

    /// A row of `range` items from the item list: its height and each
    /// picture's width, which together fill the row's width.
    struct Row: Hashable {
        let id: String
        let range: Range<Int>
        let height: CGFloat
        let widths: [CGFloat]
    }

    /// The account's own posts' pictures and clip posters, newest first. A
    /// repost is somebody else's picture and a reply belongs to a conversation,
    /// so neither is listed; a post's pictures stay together in their order.
    static func items(from tweets: [Tweet]) -> [Item] {
        var seen = Set<String>()
        var items: [Item] = []
        for tweet in tweets where tweet.retweetedBy == nil && tweet.inReplyToTweetID == nil {
            guard seen.insert(tweet.restID).inserted else { continue }
            for (index, media) in tweet.media.enumerated() {
                guard media.kind == .photo || media.isVideo, let url = URL(string: media.url) else { continue }
                items.append(Item(
                    id: "\(tweet.restID)#\(index)", tweetID: tweet.restID, mediaIndex: index,
                    url: ImageRendition.small(url), isVideo: media.isVideo, ratio: media.aspectRatio,
                    hasAlt: !(media.altText ?? "").isEmpty))
            }
        }
        return items
    }

    /// The shape a picture is laid out at: its own, within a ninth-by-sixteen
    /// portrait and a five-by-two panorama, beyond which it is shown whole in
    /// a tile of that shape. Unknown shapes are square.
    static func layoutRatio(_ source: CGFloat?) -> CGFloat {
        guard let source, source > 0 else { return 1 }
        return min(max(source, MediaShape.tallestInGroup), MediaShape.widestInGroup)
    }

    /// Justified rows for `ratios` across `width`. A row takes pictures until
    /// its height at full width falls to the target, keeping the one that
    /// tips it over only when that lands nearer the target; four at most. The
    /// last row keeps the target height instead of stretching when it would
    /// otherwise come out more than twice as tall as the rest.
    static func rows(ratios: [CGFloat?], width: CGFloat) -> [Row] {
        guard width > 0, !ratios.isEmpty else { return [] }
        let shapes = ratios.map(layoutRatio)
        var rows: [Row] = []
        var start = 0
        while start < shapes.count {
            let end = rowEnd(from: start, shapes: shapes, width: width)
            rows.append(makeRow(range: start..<end, shapes: shapes, width: width,
                                isLast: end == shapes.count))
            start = end
        }
        return rows
    }

    private static func height(of shapes: ArraySlice<CGFloat>, width: CGFloat) -> CGFloat {
        (width - gutter * CGFloat(shapes.count - 1)) / shapes.reduce(0, +)
    }

    private static func rowEnd(from start: Int, shapes: [CGFloat], width: CGFloat) -> Int {
        var end = start + 1
        while end < shapes.count, end - start < maxPerRow,
              height(of: shapes[start..<end], width: width) > targetHeight {
            end += 1
        }
        let count = end - start
        guard count > 1, height(of: shapes[start..<end], width: width) < targetHeight else { return end }
        let without = height(of: shapes[start..<end - 1], width: width)
        let with = height(of: shapes[start..<end], width: width)
        return without - targetHeight < targetHeight - with ? end - 1 : end
    }

    private static func makeRow(range: Range<Int>, shapes: [CGFloat], width: CGFloat, isLast: Bool) -> Row {
        let slice = shapes[range]
        let justified = height(of: slice, width: width)
        let stretches = !(isLast && justified > targetHeight * lastRowStretchLimit)
        let rowHeight = stretches ? justified : targetHeight
        var widths = slice.map { $0 * rowHeight }
        if stretches, let last = widths.indices.last {
            let used = widths.dropLast().reduce(0, +) + gutter * CGFloat(widths.count - 1)
            widths[last] = width - used
        }
        return Row(id: "row-\(range.lowerBound)-\(range.count)", range: range, height: rowHeight, widths: widths)
    }
}
