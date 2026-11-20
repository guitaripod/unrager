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
/// time. So a new width opens the board at a seam on the post the reader was
/// looking at: from the seam down the posts are laid out top-down and measured
/// as far as a screenful past it, and above the seam they are stacked upward,
/// from what is known or a guess, so their heights never move what is below.
/// The guesses are measured a few at a time once the frame is up, nearest the
/// screen first, and the board keeps the reader's post where it was when they
/// land. The cost of a resize is a screenful whatever the depth. Stacked upward,
/// the columns would end unevenly at the board's top, so the topmost posts are
/// placed to level them and any remainder widens a few gaps near the top. A
/// reader near the top, or a width every post above the reader is known at,
/// lays out top-down as before.
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
    /// How far past the screen, in screens, the posts measured before the frame
    /// goes up reach.
    static let measuredReach: CGFloat = 0.25
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
    /// Measures the guessed posts in what each frame leaves over.
    private lazy var refiner = IdleFrameWork { [weak self] deadline in
        self?.refine(until: deadline) ?? false
    }
    /// What measuring one post has been costing lately, so a slice only starts
    /// a post it can finish before the frame's deadline.
    private var measureCost: CFTimeInterval = 0.004
    /// Frames in a row that a guessed post within a screen of the reader could
    /// not be measured for want of time.
    private var starvedFrames = 0
    /// The post at the top of the screen when the board was last rebuilt, and
    /// how far into it the screen began, so a new width keeps it there.
    private var anchor: (item: Int, within: CGFloat)?
    private var revision = 0
    /// The width and column count of the last build, kept through invalidation,
    /// so a rebuild can tell a new width from a refresh at the same one.
    private var builtShape: (width: CGFloat, columns: Int)?
    /// The first post laid out top-down; the ones before it are stacked upward
    /// from it. Kept until the width changes again.
    private(set) var seam = 0
    /// Where the seam lay in the last build, so a rebuild at the same width can
    /// place the screen against it.
    private var seamLine: CGFloat = 0
    private var builtCount = 0

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
        guard let collectionView, collectionView.bounds.width > 0 else { return }
        let width = collectionView.bounds.width
        let count = numberOfItems?() ?? 0
        let columns = columns(for: width)
        let key = BuildKey(width: width, items: count, columns: columns, header: headerHeight, revision: revision)
        guard key != builtFor else { return }
        let widthChanged = builtShape.map { $0.width != width || $0.columns != columns } ?? false
        let screen = collectionView.bounds.height
        let screenTopNow = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        if widthChanged {
            anchor = topItem()
            seam = anchor.map { seamFor($0.item) } ?? 0
        } else if let first = firstAnchor {
            anchor = (first, 0)
            seam = seamFor(first)
        } else {
            anchor = nil
            if count != builtCount, (topItem()?.item ?? 0) < columns * 3 { seam = 0 }
        }
        firstAnchor = nil
        seam = min(seam, count)
        builtShape = (width, columns)
        builtFor = key
        builtCount = count
        guessed = []
        let screenTop = anchor?.within ?? (screenTopNow - seamLine)

        itemAttributes = []
        headerAttributes = nil
        footerAttributes = nil

        resolvedColumns = columns
        let itemWidth = Self.columnWidth(for: width, columns: columns, spacing: columnSpacing,
                                         inset: sectionInset.left + sectionInset.right)
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

        var frames = [CGRect](repeating: .zero, count: count)
        var heights = [CGFloat](repeating: 0, count: seam)
        var bottoms = [CGFloat](repeating: -itemSpacing, count: columns)
        let bandTop = screenTop - screen * Self.measuredReach
        let bandBottom = screenTop + screen * (1 + Self.measuredReach)
        for item in stride(from: seam - 1, through: 0, by: -1) {
            let indexPath = IndexPath(item: item, section: 0)
            let column = Self.tallestStack(bottoms)
            let guess = knownHeightForItem?(indexPath) ?? estimatedHeightForItem?(indexPath) ?? 320
            let visible = bottoms[column] > bandTop && bottoms[column] - guess < bandBottom
            heights[item] = max(44, height(at: indexPath, measuring: visible))
            bottoms[column] -= heights[item] + itemSpacing
        }
        let headerTop = sectionInset.top + headerHeight
        let stacks = Self.stacks(above: heights, columns: columns, spacing: itemSpacing)
        let tallest = stacks.map(\.height).max() ?? 0
        for (column, stack) in stacks.enumerated() where !stack.items.isEmpty {
            let deficit = tallest - stack.height
            let gaps = min(stack.items.count, max(4, Int((deficit / Self.widenedGap).rounded(.up))))
            let extra = deficit / CGFloat(gaps)
            var y = headerTop
            for (place, item) in stack.items.enumerated() {
                frames[item] = CGRect(x: columnX[column], y: y, width: itemWidth, height: heights[item])
                y += heights[item] + itemSpacing + (place < gaps ? extra : 0)
            }
        }
        seamLine = seam > 0 ? headerTop + tallest + itemSpacing : headerTop

        var tops = [CGFloat](repeating: seamLine, count: columns)
        let reach = screen * (1 + Self.measuredReach)
        var screenBottom = anchor == nil ? screenTopNow + reach : .greatestFiniteMagnitude
        for item in seam..<count {
            let indexPath = IndexPath(item: item, section: 0)
            let shortest = tops.indices.min { tops[$0] < tops[$1] } ?? 0
            if item == anchor?.item { screenBottom = tops[shortest] + (anchor?.within ?? 0) + reach }
            let upToReader = anchor.map { item <= $0.item } ?? false
            let height = max(44, height(at: indexPath, measuring: upToReader || tops[shortest] < screenBottom))
            frames[item] = CGRect(x: columnX[shortest], y: tops[shortest], width: itemWidth, height: height)
            tops[shortest] += height + itemSpacing
        }

        itemAttributes = frames.enumerated().map { item, frame in
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: item, section: 0))
            attributes.frame = frame
            return attributes
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
        let readerTop = anchor.flatMap { frames.indices.contains($0.item) ? frames[$0.item].minY + $0.within : nil }
        let middle = (readerTop ?? screenTopNow) + screen / 2
        guessed.sort { abs(frames[$0].midY - middle) < abs(frames[$1].midY - middle) }
        refineSoon()
    }

    /// Where a board opened on `item` begins laying out top-down: at that post,
    /// unless it is near the top or every post above it is already known at
    /// this width, in which case the whole board is laid out top-down exactly
    /// as it was before.
    private func seamFor(_ item: Int) -> Int {
        guard item > Self.topDownDepth else { return 0 }
        let allKnown = (0..<item).allSatisfy { knownHeightForItem?(IndexPath(item: $0, section: 0)) != nil }
        return allKnown ? 0 : item
    }

    /// How many posts above the reader a resize measures outright rather than
    /// opening a seam: a few dozen cost less than a frame or two.
    static let topDownDepth = 40
    /// The most a gap between two posts above the seam is widened by, roughly,
    /// to bring the columns' tops level.
    static let widenedGap: CGFloat = 12

    /// The posts above the seam, column by column from the top, each column's
    /// height with the usual spacing. Each post goes on the shortest stack, as
    /// the board does below the seam, except the topmost few, which are placed
    /// to bring the stacks as level as they can, so the board's top starts its
    /// columns together; what is left over widens the gaps between the topmost
    /// posts of the shorter columns a little.
    static func stacks(above heights: [CGFloat], columns: Int, spacing: CGFloat)
        -> [(items: [Int], height: CGFloat)]
    {
        var column = [Int](repeating: 0, count: heights.count)
        var height = [CGFloat](repeating: 0, count: columns)
        let balanced = min(heights.count, columns >= 4 ? 6 : 8)
        for item in stride(from: heights.count - 1, through: balanced, by: -1) {
            let shortest = height.indices.min { height[$0] < height[$1] } ?? 0
            column[item] = shortest
            height[shortest] += heights[item] + spacing
        }
        var best: (spread: CGFloat, picks: [Int])?
        var picks = [Int](repeating: 0, count: balanced)
        let combinations = (0..<balanced).reduce(1) { total, _ in total * columns }
        for code in 0..<combinations {
            var trial = height
            var rest = code
            for item in 0..<balanced {
                picks[item] = rest % columns
                rest /= columns
                trial[picks[item]] += heights[item] + spacing
            }
            let spread = (trial.max() ?? 0) - (trial.min() ?? 0)
            if best == nil || spread < (best?.spread ?? 0) - 0.5 { best = (spread, picks) }
        }
        for item in 0..<balanced { column[item] = best?.picks[item] ?? 0 }
        return (0..<columns).map { which in
            let items = heights.indices.filter { column[$0] == which }
            let total = items.reduce(0) { $0 + heights[$1] } + spacing * CGFloat(max(items.count - 1, 0))
            return (items, total)
        }
    }

    /// The column whose upward stack is shortest, so the next post above the
    /// seam goes on top of it; the leftmost on a tie.
    private static func tallestStack(_ bottoms: [CGFloat]) -> Int {
        var best = 0
        for column in bottoms.indices where bottoms[column] > bottoms[best] { best = column }
        return best
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
        refiner.stop()
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

    /// Measures the guessed posts after each frame is drawn, nearest the screen
    /// first, in the time that frame leaves over (`IdleFrameWork`), and lays the
    /// board out again once they are all known — or sooner when the reader
    /// scrolls to within a screen of one still guessed. Laying the board out
    /// after every few posts would cost a pass of the whole board each time.
    private func refineSoon() {
        guard !guessed.isEmpty, !retired else { return }
        starvedFrames = 0
        guard collectionView?.window != nil else { return refineOffScreen() }
        refiner.start()
    }

    /// A board not on screen has no frames of its own to keep on time: it
    /// measures in turns of the main queue, a slice at a time.
    private func refineOffScreen() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.guessed.isEmpty, !self.refiner.isRunning else { return }
            if self.refine(until: CACurrentMediaTime() + IdleFrameWork.fallbackSlice) { self.refineSoon() }
        }
    }

    /// One frame's share: as many guessed posts as fit before `deadline`. A post
    /// within a screen of the reader that has waited three frames for room is
    /// measured anyway, since showing it at its guessed height would be worse
    /// than one late frame. Answers whether any are left.
    private func refine(until deadline: CFTimeInterval) -> Bool {
        guard !retired else { return false }
        var measured = false
        while let item = guessed.first {
            let started = CACurrentMediaTime()
            let near = guessNearScreen
            guard started + measureCost < deadline || (near && starvedFrames >= Self.starvationLimit) else {
                if near { starvedFrames += 1 }
                break
            }
            guessed.removeFirst()
            let indexPath = IndexPath(item: item, section: 0)
            guard item < (numberOfItems?() ?? 0), knownHeightForItem?(indexPath) == nil else { continue }
            _ = heightForItem?(indexPath)
            measureCost = max(0.0005, measureCost * 0.7 + (CACurrentMediaTime() - started) * 0.3)
            measured = true
            starvedFrames = 0
        }
        if guessed.isEmpty {
            relayoutKeepingReader()
            return !guessed.isEmpty
        }
        if measured, guessNearScreen { relayoutKeepingReader() }
        return true
    }

    /// Frames a near guessed post may wait for room before it is measured in a
    /// frame that has none.
    static let starvationLimit = 3

    /// Lays the board out again with what has been measured, keeping the post
    /// at the top of the screen where it is: a post above the seam that turns
    /// out taller than its guess moves the seam down, and the screen with it.
    private func relayoutKeepingReader() {
        let kept = topItem()
        revision += 1
        invalidateLayout()
        guard let kept, let collectionView, collectionView.window != nil else { return }
        collectionView.layoutIfNeeded()
        guard itemAttributes.indices.contains(kept.item) else { return }
        let inset = collectionView.adjustedContentInset
        let wanted = itemAttributes[kept.item].frame.minY + kept.within - inset.top
        let lowest = max(-inset.top, contentSize.height + inset.bottom - collectionView.bounds.height)
        let offset = min(max(-inset.top, wanted), lowest)
        guard abs(offset - collectionView.contentOffset.y) > 0.5 else { return }
        collectionView.contentOffset.y = offset
    }

    /// Whether a post still laid out by a guess sits within a screen of what
    /// the reader can see, above or below.
    private var guessNearScreen: Bool {
        guard let collectionView, let item = guessed.first, itemAttributes.indices.contains(item) else { return false }
        let top = collectionView.contentOffset.y - collectionView.bounds.height
        let bottom = collectionView.contentOffset.y + collectionView.bounds.height * 2
        let frame = itemAttributes[item].frame
        return frame.maxY > top && frame.minY < bottom
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
