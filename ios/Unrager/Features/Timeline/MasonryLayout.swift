import UIKit

/// A two-column masonry layout for the feed on a wide iPad window: every post
/// takes the narrowest column with room, so pictures and long posts sit beside
/// short ones instead of leaving a ragged row, and the whole board scrolls as
/// one list.
///
/// Heights come from the caller, which measures a real `TweetCell` and keeps the
/// answer: a feed's rows are self-sizing in a list, and a custom layout has to
/// know a row's height before it can place the one after it. Everything is
/// rebuilt when the column width, the number of posts or the header changes, and
/// left alone while scrolling.
final class MasonryLayout: UICollectionViewLayout {
    /// How narrow a column may get before the board drops one: about a phone's
    /// width of text, so a picture post still reads.
    static let minimumColumnWidth: CGFloat = 300
    static let maximumColumns = 4
    var columnSpacing: CGFloat = 10
    var itemSpacing: CGFloat = 10
    var sectionInset = UIEdgeInsets(top: 8, left: 10, bottom: 24, right: 10)
    var headerHeight: CGFloat = 0
    var footerHeight: CGFloat = 56
    /// The height of the post at `indexPath`, in points.
    var heightForItem: ((IndexPath) -> CGFloat)?
    /// How many posts there are. Asked instead of the collection view, which
    /// can't be queried while its layout is being installed.
    var numberOfItems: (() -> Int)?

    private(set) var resolvedColumns = 1
    private var itemAttributes: [UICollectionViewLayoutAttributes] = []
    private var headerAttributes: UICollectionViewLayoutAttributes?
    private var footerAttributes: UICollectionViewLayoutAttributes?
    private var contentSize: CGSize = .zero
    private var builtFor: BuildKey?

    private struct BuildKey: Equatable {
        var width: CGFloat
        var items: Int
        var columns: Int
        var header: CGFloat
    }

    /// The width of one column in the current layout, for the cells that
    /// measure their text and pictures against it.
    var columnWidth: CGFloat {
        Self.columnWidth(for: collectionView?.bounds.width ?? 0,
                         columns: Self.columns(for: collectionView?.bounds.width ?? 0),
                         spacing: columnSpacing, inset: sectionInset.left + sectionInset.right)
    }

    /// How many columns fit across `width` at the board's minimum: two on a
    /// portrait iPad, three or four across a landscape one.
    static func columns(for width: CGFloat) -> Int {
        let perColumn = minimumColumnWidth
        let count = Int(((width + 10) / (perColumn + 10)).rounded(.down))
        return min(max(count, 1), maximumColumns)
    }

    private static func columnWidth(for width: CGFloat, columns: Int, spacing: CGFloat, inset: CGFloat) -> CGFloat {
        let spacing = CGFloat(max(columns - 1, 0)) * spacing
        return max(80, ((width - inset - spacing) / CGFloat(max(columns, 1))).rounded(.down))
    }

    /// The item width a layout attributes would get — the collection view pads
    /// a fractional width away, and the cells should measure what they get.
    override var collectionViewContentSize: CGSize { contentSize }

    override func prepare() {
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        let count = numberOfItems?() ?? 0
        let columns = Self.columns(for: width)
        let key = BuildKey(width: width, items: count, columns: columns, header: headerHeight)
        guard key != builtFor else { return }
        builtFor = key

        itemAttributes = []
        headerAttributes = nil
        footerAttributes = nil

        resolvedColumns = columns
        let itemWidth = Self.columnWidth(for: width, columns: columns, spacing: columnSpacing,
                                         inset: sectionInset.left + sectionInset.right)
        var tops = [CGFloat](repeating: sectionInset.top + headerHeight, count: columns)
        let usable = width - sectionInset.left - sectionInset.right
        let spacing = CGFloat(columns - 1) * columnSpacing
        let slot = (usable - spacing) / CGFloat(columns)
        let columnX = (0..<columns).map { sectionInset.left + CGFloat($0) * (slot + columnSpacing) }

        if headerHeight > 0 {
            let header = UICollectionViewLayoutAttributes(
                forSupplementaryViewOfKind: FeedViewController.headerKind,
                with: IndexPath(item: 0, section: 0))
            header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
            header.zIndex = 1
            headerAttributes = header
        }

        for item in 0..<count {
            let indexPath = IndexPath(item: item, section: 0)
            let shortest = tops.indices.min { tops[$0] < tops[$1] } ?? 0
            let height = max(44, heightForItem?(indexPath) ?? 320)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            attributes.frame = CGRect(x: columnX[shortest], y: tops[shortest], width: itemWidth, height: height)
            itemAttributes.append(attributes)
            tops[shortest] += height + itemSpacing
        }

        let board = (tops.max() ?? sectionInset.top + headerHeight) - itemSpacing + sectionInset.bottom
        contentSize = CGSize(width: width, height: max(board, collectionView.bounds.height))

        if footerHeight > 0, count > 0 {
            let footer = UICollectionViewLayoutAttributes(
                forSupplementaryViewOfKind: FeedViewController.footerKind,
                with: IndexPath(item: 0, section: 0))
            footer.frame = CGRect(x: 0, y: contentSize.height - sectionInset.bottom - footerHeight,
                                  width: width, height: footerHeight)
            footerAttributes = footer
        }
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var found = itemAttributes.filter { $0.frame.intersects(rect) }
        if let headerAttributes, headerAttributes.frame.intersects(rect) { found.append(headerAttributes) }
        if let footerAttributes, footerAttributes.frame.intersects(rect) { found.append(footerAttributes) }
        return found
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        itemAttributes.indices.contains(indexPath.item) ? itemAttributes[indexPath.item] : nil
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        if elementKind == FeedViewController.headerKind { return headerAttributes }
        if elementKind == FeedViewController.footerKind { return footerAttributes }
        return nil
    }

    /// Heights are measured once and kept, so a rebuild only happens when
    /// something structural moves — never while the board is scrolling.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != builtFor?.width
    }

    override func invalidateLayout() {
        builtFor = nil
        super.invalidateLayout()
    }
}
