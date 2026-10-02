import Combine
import UIKit
import UnragerKit

/// One picture or clip in the Media tab. A picture that is the tile's shape
/// fills it; one that isn't (an extreme panorama or a very tall screenshot) is
/// shown whole over a frosted copy of itself, never cropped. A clip carries a
/// play mark.
final class MediaGridTileView: UIView {
    let imageView = AsyncImageView(frame: .zero)
    private let backdrop = AmbientBackdropView(frame: .zero)
    private let playBadge = UIImageView(image: DesignSystem.icon("play.fill", pointSize: 11, weight: .bold))
    private let playPlate = UIView()
    private var key: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        accessibilityIgnoresInvertColors = true
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
        imageView.fadesIn = true
        imageView.contentMode = .scaleAspectFill
        imageView.onLoad = { [weak self] image in self?.fit(to: image) }
        addSubview(backdrop)
        addSubview(imageView)

        playPlate.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        playPlate.layer.cornerRadius = 13
        playPlate.isUserInteractionEnabled = false
        playBadge.tintColor = .white
        playPlate.addSubview(playBadge)
        addSubview(playPlate)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(item: ProfileMediaGrid.Item) {
        accessibilityLabel = item.isVideo ? "Video" : (item.hasAlt ? "Photo with description" : "Photo")
        playPlate.isHidden = !item.isVideo
        guard item.id != key || imageView.image == nil else { return }
        key = item.id
        backdrop.clear()
        guard AppSettings.imagesEnabled else {
            imageView.cancel()
            return
        }
        imageView.load(url: item.url, targetSize: bounds.size == .zero ? CGSize(width: 200, height: 200) : bounds.size)
    }

    func prepareForReuse() {
        key = nil
        imageView.cancel()
        backdrop.clear()
    }

    private func fit(to image: UIImage) {
        guard bounds.width > 0 else { return }
        let fills = MediaShape.matches(image.size, in: bounds.size)
        imageView.contentMode = fills ? .scaleAspectFill : .scaleAspectFit
        if fills {
            backdrop.clear()
        } else {
            backdrop.show(from: image, key: key ?? "tile-\(image.hash)")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        imageView.frame = bounds
        playPlate.frame = CGRect(x: 8, y: bounds.height - 34, width: 26, height: 26)
        playBadge.frame = playPlate.bounds.offsetBy(dx: 1, dy: 0)
        playBadge.contentMode = .center
        if let image = imageView.image { fit(to: image) }
    }
}

/// A row of the Media tab: up to four tiles side by side at the widths a
/// justified layout gave them.
final class MediaGridRowCell: UICollectionViewCell {
    private var tiles: [MediaGridTileView] = []
    private var row: ProfileMediaGrid.Row?
    private var items: [ProfileMediaGrid.Item] = []
    private var heightConstraint: NSLayoutConstraint!
    var onTap: ((ProfileMediaGrid.Item, MediaGridTileView) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        heightConstraint = contentView.heightAnchor.constraint(equalToConstant: ProfileMediaGrid.targetHeight)
        heightConstraint.priority = .required - 1
        heightConstraint.isActive = true
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(row: ProfileMediaGrid.Row, items: [ProfileMediaGrid.Item]) {
        self.row = row
        self.items = items
        heightConstraint.constant = row.height
        while tiles.count < items.count {
            let tile = MediaGridTileView()
            contentView.addSubview(tile)
            tiles.append(tile)
        }
        for (index, tile) in tiles.enumerated() {
            tile.isHidden = index >= items.count
        }
        setNeedsLayout()
        layoutIfNeeded()
        for (index, item) in items.enumerated() { tiles[index].configure(item: item) }
        accessibilityElements = tiles.prefix(items.count).map { $0 }
    }

    /// The tile under `point`, in the cell's own space.
    func tile(at point: CGPoint) -> (item: ProfileMediaGrid.Item, tile: MediaGridTileView)? {
        let local = contentView.convert(point, from: self)
        for (index, tile) in tiles.enumerated() where index < items.count && tile.frame.contains(local) {
            return (items[index], tile)
        }
        return nil
    }

    /// The tile showing `item`, for a viewer to grow out of.
    func tile(for item: ProfileMediaGrid.Item) -> MediaGridTileView? {
        guard let index = items.firstIndex(of: item), tiles.indices.contains(index) else { return nil }
        return tiles[index]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let row else { return }
        let scale = max(traitCollection.displayScale, 1)
        var x: CGFloat = 0
        for (index, width) in row.widths.enumerated() where tiles.indices.contains(index) {
            let minX = (x * scale).rounded() / scale
            let maxX = ((x + width) * scale).rounded() / scale
            tiles[index].frame = CGRect(x: minX, y: 0, width: maxX - minX, height: row.height)
            x += width + ProfileMediaGrid.gutter
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let hit = tile(at: gesture.location(in: self)) else { return }
        onTap?(hit.item, hit.tile)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tiles.forEach { $0.prepareForReuse() }
        row = nil
        items = []
        onTap = nil
    }
}

/// What the Media tab looks like before its first page: rows of grey tiles.
private final class MediaGridSkeletonView: SkeletonView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Loading media"
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = ProfileMediaGrid.gutter
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        let layouts: [[CGFloat]] = [[1.5, 1, 0.8], [1, 1.6], [0.8, 1.3, 1], [1.4, 1], [1, 0.9, 1.2]]
        for shares in layouts {
            let row = UIStackView()
            row.spacing = ProfileMediaGrid.gutter
            row.distribution = .fill
            let first = shape(radius: 0)
            row.addArrangedSubview(first)
            for share in shares.dropFirst() {
                let tile = shape(radius: 0)
                row.addArrangedSubview(tile)
                tile.widthAnchor.constraint(equalTo: first.widthAnchor, multiplier: share / shares[0]).isActive = true
            }
            row.heightAnchor.constraint(equalToConstant: ProfileMediaGrid.targetHeight).isActive = true
            rows.addArrangedSubview(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The Media tab of a profile: every picture and clip from the account's own
/// posts in justified rows, each at its own shape. It stands beside the Posts
/// and Replies feeds under the same scrolling header, and reads the same
/// timeline: it keeps asking for older posts until the screen is full of
/// pictures or the timeline ends.
final class ProfileMediaViewController: UIViewController {
    let viewModel: TimelineViewModel
    private(set) var collectionView: UICollectionView!
    var headerView: UIView?
    var onScroll: ((UIScrollView) -> Void)?
    var onPullToRefresh: (() -> Void)?
    var hidesEmptyState = false {
        didSet { if oldValue != hidesEmptyState, isViewLoaded { updateChrome() } }
    }

    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var cancellables = Set<AnyCancellable>()
    private var items: [ProfileMediaGrid.Item] = []
    private var rows: [ProfileMediaGrid.Row] = []
    private var tweetsByID: [String: Tweet] = [:]
    private var laidOutWidth: CGFloat = 0
    private let skeleton = MediaGridSkeletonView()
    private let emptyState = EmptyStateView()
    private let footer = PagingFooter()
    private var contentSizeObservation: NSKeyValueObservation?
    private var autoPages = 0
    private static let autoPageLimit = 8

    init(handle: String) {
        viewModel = TimelineViewModel(source: .user(handle: handle))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)
        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        collectionView.refreshControl = refresh

        skeleton.isHidden = true
        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.viewModel.refresh() }
        collectionView.addSubview(skeleton)
        collectionView.addSubview(emptyState)
        contentSizeObservation = collectionView.observe(\.contentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.positionPlaceholders() }
        }
        configureDataSource()
        bind()
        viewModel.first()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        if width > 0, width != laidOutWidth { rebuild() }
        positionPlaceholders()
    }

    @objc private func pullToRefresh() {
        autoPages = 0
        viewModel.refresh()
        onPullToRefresh?()
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let hasHeader = headerView != nil
        return UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            var supplementaries: [NSCollectionLayoutBoundarySupplementaryItem] = []
            if hasHeader {
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(160))
                supplementaries.append(NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: size, elementKind: FeedViewController.headerKind, alignment: .top))
            }
            supplementaries.append(PagingFooter.boundaryItem())
            section.boundarySupplementaryItems = supplementaries
            return section
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<MediaGridRowCell, String> { [weak self] cell, _, id in
            guard let self, let row = self.rows.first(where: { $0.id == id }) else { return }
            cell.configure(row: row, items: Array(self.items[row.range]))
            cell.onTap = { [weak self] item, tile in self?.open(item, from: tile) }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: registration, for: ip, item: id)
        }
        footer.attach(to: collectionView)
        footer.onRetry = { [weak self] in self?.loadMore() }
        footer.install(on: dataSource)
        let footerProvider = dataSource.supplementaryViewProvider
        let headerRegistration = UICollectionView.SupplementaryRegistration<HostReusableView>(
            elementKind: FeedViewController.headerKind) { [weak self] host, _, _ in
            if let header = self?.headerView { host.host(header) }
        }
        dataSource.supplementaryViewProvider = { cv, kind, ip in
            kind == FeedViewController.headerKind
                ? cv.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: ip)
                : footerProvider?(cv, kind, ip)
        }
    }

    // MARK: - Data

    private func bind() {
        viewModel.tweets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tweets in self?.update(from: tweets) }
            .store(in: &cancellables)
        viewModel.isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                if !loading { self?.collectionView.refreshControl?.endRefreshing() }
                self?.updateChrome()
                if !loading { self?.fillScreenIfNeeded() }
            }
            .store(in: &cancellables)
    }

    private func update(from tweets: [Tweet]) {
        tweetsByID = Dictionary(tweets.map { ($0.restID, $0) }, uniquingKeysWith: { first, _ in first })
        items = ProfileMediaGrid.items(from: tweets)
        rebuild()
    }

    /// Lays the rows out for the current width and shows them.
    private func rebuild() {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        laidOutWidth = width
        rows = ProfileMediaGrid.rows(ratios: items.map(\.ratio), width: width)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id), toSection: 0)
        snapshot.reconfigureItems(rows.map(\.id).filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
        updateChrome()
        DispatchQueue.main.async { [weak self] in self?.fillScreenIfNeeded() }
    }

    /// Keeps asking for older posts while the pictures found so far don't
    /// fill the screen, within a limit, so a few pictures buried among text
    /// posts still turn up without scrolling.
    private func fillScreenIfNeeded() {
        guard isViewLoaded, view.window != nil, !viewModel.isExhausted, !viewModel.isLoading.value,
              autoPages < Self.autoPageLimit else { return }
        let rowsHeight = rows.reduce(0) { $0 + $1.height + ProfileMediaGrid.gutter }
        guard rowsHeight < collectionView.bounds.height else { return }
        autoPages += 1
        loadMore()
    }

    private func loadMore() {
        viewModel.loadMoreIfNeeded(currentIndex: max(0, viewModel.tweets.value.count - 1))
    }

    // MARK: - Chrome

    private func updateChrome() {
        let hasRows = !rows.isEmpty
        let loading = viewModel.isLoading.value || !viewModel.hasLoadedOnce
        skeleton.isHidden = hasRows || !loading || hidesEmptyState
        let showEmpty = !hasRows && !loading && !hidesEmptyState
        emptyState.isHidden = !showEmpty
        if showEmpty {
            emptyState.show(symbol: "photo.on.rectangle.angled", title: "No photos or videos",
                            subtitle: "Pictures and clips from this account's posts show up here.", showRetry: false)
        }
        if viewModel.isLoading.value, hasRows {
            footer.set(.loading("Loading more…"))
        } else if viewModel.isExhausted, hasRows {
            footer.set(.note("That's all of its media"))
        } else {
            footer.set(.hidden)
        }
        positionPlaceholders()
    }

    /// Puts the skeleton and the empty state just under the header.
    private func positionPlaceholders() {
        guard isViewLoaded, collectionView != nil else { return }
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let headerBottom = collectionView.collectionViewLayout.layoutAttributesForSupplementaryView(
            ofKind: FeedViewController.headerKind, at: IndexPath(item: 0, section: 0))?.frame.maxY ?? 0
        let skeletonFrame = CGRect(x: 0, y: headerBottom, width: width, height: 620)
        if skeleton.frame != skeletonFrame { skeleton.frame = skeletonFrame }
        let emptyFrame = CGRect(x: 0, y: headerBottom, width: width, height: 360)
        if emptyState.frame != emptyFrame { emptyState.frame = emptyFrame }
    }

    // MARK: - Opening

    /// Opens a picture in the full-screen viewer, growing out of its tile, or
    /// plays a clip.
    private func open(_ item: ProfileMediaGrid.Item, from tile: MediaGridTileView) {
        Haptics.selection()
        guard let tweet = tweetsByID[item.tweetID] else { return }
        if item.isVideo {
            let url = tweet.media[item.mediaIndex].videoURL.flatMap(URL.init)
                ?? AppEnvironment.shared.api.mediaURL(tweetID: tweet.restID, index: item.mediaIndex)
            presentFullScreenVideo(url)
            return
        }
        let photoIndices = tweet.media.enumerated().compactMap { index, media -> Int? in
            if case .photo = media.kind { return index } else { return nil }
        }
        guard let start = photoIndices.firstIndex(of: item.mediaIndex) else { return }
        let viewer = MediaViewerViewController(
            tweetID: tweet.restID, photoMediaIndices: photoIndices,
            altTexts: photoIndices.map { tweet.media[$0].altText },
            startIndex: start, placeholder: tile.imageView.image)
        viewer.enableZoom { [weak self] page in
            guard photoIndices.indices.contains(page) else { return nil }
            let mediaIndex = photoIndices[page]
            return self?.tileImageView(tweetID: tweet.restID, mediaIndex: mediaIndex)
        }
        present(viewer, animated: true)
    }

    private func tileImageView(tweetID: String, mediaIndex: Int) -> UIView? {
        for case let cell as MediaGridRowCell in collectionView.visibleCells {
            guard let item = items.first(where: { $0.tweetID == tweetID && $0.mediaIndex == mediaIndex }),
                  let tile = cell.tile(for: item) else { continue }
            return tile.imageView
        }
        return nil
    }

    private func openPost(_ item: ProfileMediaGrid.Item) {
        navigationController?.pushViewController(ThreadViewController(tweetID: item.tweetID), animated: true)
    }
}

extension ProfileMediaViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard indexPath.item >= rows.count - 2 else { return }
        loadMore()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { onScroll?(scrollView) }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let cell = collectionView.cellForItem(at: indexPath) as? MediaGridRowCell,
              let hit = cell.tile(at: collectionView.convert(point, to: cell)),
              let tweet = tweetsByID[hit.item.tweetID] else { return nil }
        return UIContextMenuConfiguration(identifier: hit.item.id as NSString, previewProvider: nil) { [weak self] _ in
            let open = UIAction(title: "Open post", image: DesignSystem.icon("text.bubble")) { _ in
                self?.openPost(hit.item)
            }
            let copy = UIAction(title: "Copy link", image: DesignSystem.icon("link")) { _ in
                UIPasteboard.general.string = tweet.url
            }
            let share = UIAction(title: "Open in X", image: DesignSystem.icon("safari")) { _ in
                if let url = URL(string: tweet.url) { UIApplication.shared.open(url) }
            }
            return UIMenu(children: [open, copy, share])
        }
    }
}
