import AVFoundation
import UIKit
import UnragerKit

/// Full-screen, swipeable, zoomable photo gallery. Loads each photo at up to
/// 2,560 px through the media proxy and the shared image pipeline (so a page
/// seen once opens instantly again and the neighbours are fetched ahead), not
/// the feed's downsampled thumbnail. Supports pinch + double-tap zoom,
/// swipe-between, swipe-down-to-dismiss, and share. Videos/GIFs are handled
/// separately by `AVPlayerViewController`.
final class MediaViewerViewController: UIViewController {
    private let tweetID: String
    private let indices: [Int]
    private var currentPage: Int

    private var collectionView: UICollectionView!
    private let pageControl = UIPageControl()
    private let closeButton = UIButton(configuration: .plain())
    private let shareButton = UIButton(configuration: .plain())
    private let dimView = UIView()
    private var zoomTransition: MediaZoomTransition?
    let startPage: Int
    private var placeholder: UIImage?
    private let altTexts: [String?]
    private let altButton = UIButton(configuration: .plain())
    private let captionPanel = CaptionGradientView()
    private let captionScroll = UIScrollView()
    private let captionLabel = UILabel()
    private var chromeVisible = true
    private var captionExpanded = false
    private static let maxPixel: CGFloat = 2560

    var page: Int { currentPage }

    init(tweetID: String, photoMediaIndices: [Int], altTexts: [String?] = [], startIndex: Int,
         placeholder: UIImage? = nil) {
        self.tweetID = tweetID
        self.indices = photoMediaIndices
        self.altTexts = altTexts
        let clamped = min(max(0, startIndex), max(0, photoMediaIndices.count - 1))
        self.currentPage = clamped
        self.startPage = clamped
        self.placeholder = placeholder
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
    }

    /// Opt into the App Store–style zoom from feed thumbnails. Retains the
    /// transition (the controller's `transitioningDelegate` is weak); the media
    /// grows out of the thumbnail `sourceViewProvider` gives for the tapped
    /// photo and retracts to the one for whichever photo is showing on dismiss.
    func enableZoom(sourceViewProvider: @escaping MediaZoomTransition.SourceProvider) {
        if let decoded = (sourceViewProvider(startPage) as? UIImageView)?.image { placeholder = decoded }
        let transition = MediaZoomTransition(viewer: self, sourceProvider: sourceViewProvider)
        zoomTransition = transition
        transitioningDelegate = transition
    }

    /// The image being shown for the current page and where it sits in
    /// `container` right now — under any drag or zoom — so the dismissal can
    /// start from there. Nil when no page has an image yet.
    func dismissalGeometry(in container: UIView) -> (image: UIImage, frame: CGRect)? {
        guard let cell = currentCell, let image = cell.image else { return nil }
        return (image, cell.visibleImageFrame(in: container))
    }

    /// Hides the pages once the dismissal's own snapshot has taken over, so the
    /// image isn't drawn twice while it flies back to the feed.
    func hidePhotosForTransition() {
        collectionView.alpha = 0
    }

    private var currentCell: ZoomablePhotoCell? {
        collectionView.cellForItem(at: IndexPath(item: currentPage, section: 0)) as? ZoomablePhotoCell
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override func viewDidLoad() {
        super.viewDidLoad()
        dimView.backgroundColor = .black
        view.addManaged(dimView)
        dimView.pinEdges(to: view)

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.isPagingEnabled = true
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(ZoomablePhotoCell.self, forCellWithReuseIdentifier: ZoomablePhotoCell.reuseID)
        view.addManaged(collectionView)
        collectionView.pinEdges(to: view)

        configureChrome()

        let dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        view.addGestureRecognizer(dismissPan)
        prefetchNeighbors(of: currentPage)
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    private func photoURL(at page: Int) -> URL {
        AppEnvironment.shared.api.mediaURL(tweetID: tweetID, index: indices[page])
    }

    /// Starts fetching the photos either side of `page`, so swiping to them
    /// shows the image rather than a spinner.
    private func prefetchNeighbors(of page: Int) {
        for neighbour in [page - 1, page + 1] where indices.indices.contains(neighbour) {
            ImageLoader.prefetch(photoURL(at: neighbour), maxPixel: Self.maxPixel)
        }
    }

    /// The photo's own description, or nil when it has none.
    private func altDescription(at page: Int) -> String? {
        guard altTexts.indices.contains(page), let alt = altTexts[page]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alt.isEmpty else { return nil }
        return alt
    }

    private func altText(at page: Int) -> String {
        let position = "Photo \(page + 1) of \(indices.count)"
        guard altTexts.indices.contains(page), let alt = altTexts[page], !alt.isEmpty else { return position }
        return "\(position). \(alt)"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if collectionView.contentOffset.x == 0 && currentPage > 0 {
            collectionView.scrollToItem(at: IndexPath(item: currentPage, section: 0), at: .centeredHorizontally, animated: false)
        }
    }

    private func configureChrome() {
        closeButton.configuration?.image = DesignSystem.icon("xmark", pointSize: 16, weight: .semibold)
        closeButton.configuration?.baseForegroundColor = .white
        closeButton.configuration?.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        closeButton.configuration?.cornerStyle = .capsule
        closeButton.accessibilityLabel = "Close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        shareButton.configuration?.image = DesignSystem.icon("square.and.arrow.up", pointSize: 16, weight: .semibold)
        shareButton.configuration?.baseForegroundColor = .white
        shareButton.configuration?.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        shareButton.configuration?.cornerStyle = .capsule
        shareButton.accessibilityLabel = "Share photo"
        shareButton.addAction(UIAction { [weak self] _ in self?.shareCurrent() }, for: .touchUpInside)

        pageControl.numberOfPages = indices.count
        pageControl.currentPage = currentPage
        pageControl.hidesForSinglePage = true
        pageControl.isUserInteractionEnabled = false

        configureCaption()
        view.addManaged(closeButton)
        view.addManaged(shareButton)
        view.addManaged(pageControl)
        view.addManaged(altButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            shareButton.topAnchor.constraint(equalTo: closeButton.topAnchor),
            shareButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            shareButton.widthAnchor.constraint(equalToConstant: 44),
            shareButton.heightAnchor.constraint(equalToConstant: 44),
            pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            altButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            altButton.centerYAnchor.constraint(equalTo: pageControl.centerYAnchor),
            altButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            altButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        updateCaption()
    }

    /// The "ALT" capsule at the bottom-leading corner, and the description it
    /// opens: a scrollable caption over a gradient along the bottom edge.
    private func configureCaption() {
        var alt = UIButton.Configuration.filled()
        alt.attributedTitle = AttributedString("ALT", attributes: AttributeContainer([
            .font: DesignSystem.Typography.system(13, weight: .heavy)]))
        alt.baseForegroundColor = .white
        alt.baseBackgroundColor = UIColor(white: 0.18, alpha: 0.75)
        alt.cornerStyle = .capsule
        alt.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        alt.background.backgroundInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        altButton.configuration = alt
        altButton.accessibilityLabel = "Show image description"
        altButton.addAction(UIAction { [weak self] _ in self?.setCaptionExpanded(true) }, for: .touchUpInside)

        captionLabel.numberOfLines = 0
        captionLabel.font = DesignSystem.Typography.body()
        captionLabel.textColor = .white
        captionScroll.indicatorStyle = .white
        captionScroll.addManaged(captionLabel)
        captionPanel.addManaged(captionScroll)
        captionPanel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(collapseCaption)))
        view.addManaged(captionPanel)

        let fitsContent = captionScroll.heightAnchor.constraint(equalTo: captionScroll.contentLayoutGuide.heightAnchor)
        fitsContent.priority = .defaultLow
        NSLayoutConstraint.activate([
            captionPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            captionPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            captionPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            captionScroll.topAnchor.constraint(equalTo: captionPanel.topAnchor, constant: 56),
            captionScroll.leadingAnchor.constraint(equalTo: captionPanel.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            captionScroll.trailingAnchor.constraint(equalTo: captionPanel.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            captionScroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -44),
            captionScroll.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.35),
            fitsContent,
            captionLabel.topAnchor.constraint(equalTo: captionScroll.contentLayoutGuide.topAnchor),
            captionLabel.bottomAnchor.constraint(equalTo: captionScroll.contentLayoutGuide.bottomAnchor),
            captionLabel.leadingAnchor.constraint(equalTo: captionScroll.frameLayoutGuide.leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: captionScroll.frameLayoutGuide.trailingAnchor),
        ])
    }

    private func setCaptionExpanded(_ expanded: Bool) {
        captionExpanded = expanded
        captionScroll.contentOffset = .zero
        applyChrome(animated: true)
        UIAccessibility.post(notification: .layoutChanged, argument: expanded ? captionLabel : altButton)
    }

    #if DEBUG
    /// Screenshot router entry point: opens the description as a tap on ALT would.
    func debugExpandCaption() { setCaptionExpanded(true) }
    #endif

    @objc private func collapseCaption() {
        setCaptionExpanded(false)
    }

    /// Shows the current photo's description in the caption, keeping it open
    /// across pages that have one.
    private func updateCaption() {
        captionLabel.text = altDescription(at: currentPage)
        if captionLabel.text == nil { captionExpanded = false }
        applyChrome(animated: false)
    }

    /// A single tap on the photo hides or brings back the controls, so the
    /// photo can be seen whole. VoiceOver users keep them.
    private func toggleChrome() {
        guard !UIAccessibility.isVoiceOverRunning else { return }
        chromeVisible.toggle()
        applyChrome(animated: true)
    }

    private func applyChrome(animated: Bool) {
        let hasAlt = altDescription(at: currentPage) != nil
        let states: [(UIView, Bool)] = [
            (closeButton, chromeVisible),
            (shareButton, chromeVisible),
            (pageControl, chromeVisible),
            (altButton, chromeVisible && hasAlt && !captionExpanded),
            (captionPanel, chromeVisible && hasAlt && captionExpanded),
        ]
        let apply = {
            for (view, shown) in states {
                view.alpha = shown ? 1 : 0
                view.accessibilityElementsHidden = !shown
            }
        }
        for (view, shown) in states where view !== pageControl { view.isUserInteractionEnabled = shown }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: apply)
        } else {
            apply()
        }
    }

    /// Shares the full-resolution image — never the feed-snapshot placeholder,
    /// and never the tailnet-only proxy URL (useless to any recipient outside
    /// the tailnet). If the full-res load hasn't landed yet it's fetched here,
    /// with the button disabled meanwhile; a failed fetch says so explicitly.
    private func shareCurrent() {
        if let visible = currentCell, visible.hasFullRes, let image = visible.image {
            presentShare(image)
            return
        }
        shareButton.isEnabled = false
        let url = photoURL(at: currentPage)
        Task { [weak self] in
            defer { self?.shareButton.isEnabled = true }
            guard let data = try? await URLSession.shared.data(from: url).0,
                  let image = UIImage(data: data) else {
                AppLogger.shared.warn("share full-res fetch failed: \(url)", category: .media)
                self?.presentShareFailure()
                return
            }
            self?.presentShare(image)
        }
    }

    private func presentShare(_ image: UIImage) {
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
    }

    private func presentShareFailure() {
        let alert = UIAlertController(
            title: "Couldn't load full-size image",
            message: "The full-resolution image couldn't be fetched from the server. Check the connection and try again.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .changed:
            guard translation.y > 0 else { return }
            collectionView.transform = CGAffineTransform(translationX: 0, y: translation.y)
            dimView.alpha = max(0.3, 1 - translation.y / 400)
        case .ended, .cancelled:
            if translation.y > 140 || gesture.velocity(in: view).y > 800 {
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.25) {
                    self.collectionView.transform = .identity
                    self.dimView.alpha = 1
                }
            }
        default: break
        }
    }
}

extension MediaViewerViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { indices.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ZoomablePhotoCell.reuseID, for: indexPath) as! ZoomablePhotoCell
        let seed = indexPath.item == startPage ? placeholder : nil
        cell.load(url: photoURL(at: indexPath.item), maxPixel: Self.maxPixel, placeholder: seed,
                  accessibilityText: altText(at: indexPath.item))
        cell.onSingleTap = { [weak self] in self?.toggleChrome() }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let page = Int((scrollView.contentOffset.x + width / 2) / width)
        if page != currentPage, page >= 0, page < indices.count {
            currentPage = page
            pageControl.currentPage = page
            prefetchNeighbors(of: page)
            updateCaption()
            UIAccessibility.post(notification: .pageScrolled, argument: altText(at: page))
        }
    }
}

extension MediaViewerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: view)
        guard abs(v.y) > abs(v.x) else { return false }
        return currentCell?.isAtMinimumZoom ?? true
    }
}

/// A paging cell hosting a pinch/double-tap zoomable photo loaded at full size,
/// with a spinner while it loads and a tap-to-retry message when it can't.
private final class ZoomablePhotoCell: UICollectionViewCell, UIScrollViewDelegate {
    static let reuseID = "ZoomablePhotoCell"

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failureButton = UIButton(configuration: .tinted())
    private var task: Task<Void, Never>?
    private var retry: (() -> Void)?
    var onSingleTap: (() -> Void)?

    var image: UIImage? { imageView.image }
    /// True once the full-size download replaced the feed-snapshot placeholder
    /// — the only state whose `image` is worth sharing.
    private(set) var hasFullRes = false
    var isAtMinimumZoom: Bool { scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        contentView.addManaged(scrollView)
        scrollView.pinEdges(to: contentView)

        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds
        imageView.accessibilityIgnoresInvertColors = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        contentView.addManaged(spinner)

        var failure = UIButton.Configuration.tinted()
        failure.title = "Couldn't load — tap to retry"
        failure.image = DesignSystem.icon("arrow.clockwise", pointSize: 14)
        failure.imagePadding = 6
        failure.cornerStyle = .capsule
        failure.baseForegroundColor = .white
        failure.baseBackgroundColor = .white
        failureButton.configuration = failure
        failureButton.isHidden = true
        failureButton.addAction(UIAction { [weak self] _ in self?.retry?() }, for: .touchUpInside)
        contentView.addManaged(failureButton)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failureButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            failureButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func load(url: URL, maxPixel: CGFloat, placeholder: UIImage? = nil, accessibilityText: String) {
        task?.cancel()
        scrollView.setZoomScale(1, animated: false)
        hasFullRes = false
        imageView.image = placeholder
        accessibilityLabel = accessibilityText
        retry = { [weak self] in
            self?.load(url: url, maxPixel: maxPixel, placeholder: placeholder, accessibilityText: accessibilityText)
        }
        failureButton.isHidden = true
        spinner.startAnimating()
        layoutImage()
        task = Task { [weak self] in
            let loaded = await ImageLoader.image(for: url, maxPixel: maxPixel)
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimating()
            if let loaded {
                self.imageView.image = loaded
                self.hasFullRes = true
                if self.isAtMinimumZoom { self.layoutImage() }
            } else {
                self.failureButton.isHidden = false
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isAtMinimumZoom { layoutImage() }
    }

    private func layoutImage() {
        imageView.frame = bounds
        scrollView.contentSize = bounds.size
    }

    /// Where the photo itself (not its letterboxed view) sits in `container`.
    func visibleImageFrame(in container: UIView) -> CGRect {
        guard let image = imageView.image else { return imageView.convert(imageView.bounds, to: container) }
        let fitted = AVMakeRect(aspectRatio: image.size, insideRect: imageView.bounds)
        return imageView.convert(fitted, to: container)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let offsetX = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let offsetY = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        imageView.center = CGPoint(x: scrollView.contentSize.width / 2 + offsetX,
                                   y: scrollView.contentSize.height / 2 + offsetY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        scrollView.setZoomScale(1, animated: false)
        imageView.image = nil
        hasFullRes = false
        retry = nil
        spinner.stopAnimating()
        failureButton.isHidden = true
    }
}

/// A clear-to-black gradient down to the bottom edge, so the white caption
/// reads over any photo.
private final class CaptionGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                           UIColor.black.withAlphaComponent(0.6).cgColor,
                           UIColor.black.withAlphaComponent(0.85).cgColor]
        gradient.locations = [0, 0.3, 1]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
