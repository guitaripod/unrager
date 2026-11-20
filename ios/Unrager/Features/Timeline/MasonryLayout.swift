import UIKit

/// A masonry layout for the feed on an iPad window: every post takes the
/// narrowest column with room, so pictures and long posts sit beside short ones
/// instead of leaving a ragged row, and the whole board scrolls as one list.
///
/// Heights come from the caller, which measures a real `TweetCell` and keeps the
/// answer: a feed's rows are self-sizing in a list, and a custom layout has to
/// know a row's height before it can place the one after it. Everything is
/// rebuilt when the column width, the number of posts or the header changes, and
/// left alone while scrolling.
///
/// Measuring a post costs about a millisecond, so a board of a few hundred posts
/// measured whole at a new width keeps a resized window waiting half a second,
/// and iPadOS shows the app's old frame stretched into the new tile all that
/// time. So a rebuild measures only the posts from the top down to a screenful
/// past the one the reader is looking at, takes the rest from what is known or
/// a guess, and measures those a few at a time once the frame is up. They all
/// sit below the screen, so nothing the reader sees moves.
final class MasonryLayout: UICollectionViewLayout {
    /// How narrow a column may get before the board drops one: about a phone's
    /// width of text, so a picture post still reads. A window overrides both
    /// this and the cap with `PadLayout.board(window:)`.
    static let minimumColumnWidth: CGFloat = 300
    static let maximumColumns = 4
    var minimumColumnWidth: CGFloat = MasonryLayout.minimumColumnWidth
    var maximumColumns: Int = MasonryLayout.maximumColumns
    var columnSpacing: CGFloat = 10
    var itemSpacing: CGFloat = 10
    var sectionInset = UIEdgeInsets(top: 8, left: 10, bottom: 24, right: 10)
    var headerHeight: CGFloat = 0
    var footerHeight: CGFloat = 56
    /// The height of the post at `indexPath`, in points, measured if need be.
    var heightForItem: ((IndexPath) -> CGFloat)?
    /// The height of the post at `indexPath` if it was already measured at the
    /// current column width, without measuring.
    var knownHeightForItem: ((IndexPath) -> CGFloat?)?
    /// A cheap guess at the post's height, for one below the screen that has
    /// not been measured yet.
    var estimatedHeightForItem: ((IndexPath) -> CGFloat)?
    /// The most posts past the one at the top of the screen measured before the
    /// frame goes up; fewer when a screenful is filled sooner.
    static let measuredAhead = 16
    /// How many posts there are. Asked instead of the collection view, which
    /// can't be queried while its layout is being installed.
    var numberOfItems: (() -> Int)?

    private(set) var resolvedColumns = 1
    private var itemAttributes: [UICollectionViewLayoutAttributes] = []
    private var headerAttributes: UICollectionViewLayoutAttributes?
    private var footerAttributes: UICollectionViewLayoutAttributes?
    private var contentSize: CGSize = .zero
    private var builtFor: BuildKey?
    /// Posts laid out with a guess, measured a few at a time after the frame.
    private var guessed: [Int] = []
    private var refining = false
    /// The post at the top of the screen when the board was last rebuilt, and
    /// how far into it the screen began, so a new width keeps it there.
    private var anchor: (item: Int, within: CGFloat)?
    private var revision = 0
    /// The width and column count of the last build, kept through invalidation,
    /// so a rebuild can tell a new width from a refresh at the same one.
    private var builtShape: (width: CGFloat, columns: Int)?

    private struct BuildKey: Equatable {
        var width: CGFloat
        var items: Int
        var columns: Int
        var header: CGFloat
        var revision: Int
    }

    /// The width of one column in the current layout, for the cells that
    /// measure their text and pictures against it.
    var columnWidth: CGFloat {
        Self.columnWidth(for: collectionView?.bounds.width ?? 0,
                         columns: columns(for: collectionView?.bounds.width ?? 0),
                         spacing: columnSpacing, inset: sectionInset.left + sectionInset.right)
    }

    /// How many columns fit across `width` at the board's own minimum — pure
    /// arithmetic, so it can be asked without a layout or a main thread.
    static func columns(for width: CGFloat) -> Int {
        columns(for: width, minimum: minimumColumnWidth, maximum: maximumColumns, spacing: 10)
    }

    static func columns(for width: CGFloat, minimum: CGFloat, maximum: Int, spacing: CGFloat) -> Int {
        let count = Int(((width + spacing) / (minimum + spacing)).rounded(.down))
        return min(max(count, 1), maximum)
    }

    func columns(for width: CGFloat) -> Int {
        Self.columns(for: width, minimum: minimumColumnWidth, maximum: maximumColumns, spacing: columnSpacing)
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
        let columns = columns(for: width)
        let key = BuildKey(width: width, items: count, columns: columns, header: headerHeight, revision: revision)
        guard key != builtFor else { return }
        let widthChanged = builtShape.map { $0.width != width || $0.columns != columns } ?? false
        anchor = widthChanged ? topItem() : firstAnchor.map { ($0, 0) }
        firstAnchor = nil
        builtShape = (width, columns)
        builtFor = key
        guessed = []
        let startItem = anchor?.item ?? topItem()?.item ?? 0
        let screen = collectionView.bounds.height
        var screenBottom = CGFloat.greatestFiniteMagnitude

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
            if item == startItem { screenBottom = tops[shortest] + (anchor?.within ?? 0) + screen * 1.25 }
            let onScreen = item <= startItem
                || (item <= startItem + Self.measuredAhead && tops[shortest] < screenBottom)
            let height = max(44, height(at: indexPath, measuring: onScreen))
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
        refineSoon()
    }

    private func height(at indexPath: IndexPath, measuring: Bool) -> CGFloat {
        if let known = knownHeightForItem?(indexPath) { return known }
        if retired { return 320 }
        if measuring || estimatedHeightForItem == nil { return heightForItem?(indexPath) ?? 320 }
        guessed.append(indexPath.item)
        return estimatedHeightForItem?(indexPath) ?? 320
    }

    /// Opens a board that takes over from a list on the post the list had at
    /// the top of the screen.
    func anchorOnFirstBuild(_ item: Int?) {
        firstAnchor = item
    }

    private var firstAnchor: Int?
    private var retired = false

    /// A board being replaced by the list is still asked to lay itself out
    /// once at the new width as the list takes over; it answers from what it
    /// knows and measures nothing for a board nobody will see.
    func retire() {
        retired = true
        guessed = []
    }

    /// The post nearest the top of the screen and how far down it the screen
    /// starts, read from the board as it stood before this rebuild.
    private func topItem() -> (item: Int, within: CGFloat)? {
        guard let collectionView, !itemAttributes.isEmpty else { return nil }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let first = itemAttributes
            .filter { $0.frame.maxY > top }
            .min { $0.frame.minY < $1.frame.minY }
        guard let first else { return nil }
        return (first.indexPath.item, top - first.frame.minY)
    }

    /// Measures the guessed posts a few milliseconds at a time, after the frame
    /// is up, and lays the board out again once they are all known — or sooner
    /// when the reader scrolls to within a screen of one still guessed. Laying
    /// the board out after every few posts would cost a pass of the whole
    /// window, focus map included, for posts nobody can see yet.
    private func refineSoon() {
        guard !guessed.isEmpty, !refining, !retired else { return }
        refining = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refining = false
            let started = CACurrentMediaTime()
            while let item = self.guessed.first, CACurrentMediaTime() - started < 0.008 {
                self.guessed.removeFirst()
                let indexPath = IndexPath(item: item, section: 0)
                guard item < (self.numberOfItems?() ?? 0), self.knownHeightForItem?(indexPath) == nil else { continue }
                _ = self.heightForItem?(indexPath)
            }
            if self.guessed.isEmpty || self.guessNearScreen {
                self.revision += 1
                self.invalidateLayout()
            } else {
                self.refineSoon()
            }
        }
    }

    /// Whether a post still laid out by a guess sits within a screen of what
    /// the reader can see.
    private var guessNearScreen: Bool {
        guard let collectionView, let item = guessed.first, itemAttributes.indices.contains(item) else { return false }
        let reach = collectionView.contentOffset.y + collectionView.bounds.height * 2
        return itemAttributes[item].frame.minY < reach
    }

    /// A new width keeps the post the reader was on at the top of the screen,
    /// at the same depth into it.
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let anchor, let collectionView, itemAttributes.indices.contains(anchor.item) else {
            return super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
        }
        let inset = collectionView.adjustedContentInset
        let wanted = itemAttributes[anchor.item].frame.minY + anchor.within - inset.top
        let lowest = max(-inset.top, contentSize.height + inset.bottom - collectionView.bounds.height)
        return CGPoint(x: proposedContentOffset.x, y: min(max(-inset.top, wanted), lowest))
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
