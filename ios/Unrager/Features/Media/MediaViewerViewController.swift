import UIKit
import UnragerKit

/// Full-screen, swipeable, zoomable photo gallery. Loads each photo at full
/// resolution through the media proxy (not the feed's downsampled thumbnail),
/// supports pinch + double-tap zoom, swipe-between, swipe-down-to-dismiss, and
/// share. Videos/GIFs are handled separately by `AVPlayerViewController`.
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
    private let startPage: Int
    private let placeholder: UIImage?

    init(tweetID: String, photoMediaIndices: [Int], startIndex: Int, placeholder: UIImage? = nil) {
        self.tweetID = tweetID
        self.indices = photoMediaIndices
        let clamped = min(max(0, startIndex), max(0, photoMediaIndices.count - 1))
        self.currentPage = clamped
        self.startPage = clamped
        self.placeholder = placeholder
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    /// Opt into the App Store–style zoom from a feed thumbnail. Retains the
    /// transition (the controller's `transitioningDelegate` is weak) and grows
    /// the media out of `sourceView`, retracting to it on dismiss.
    func enableZoom(from sourceView: UIView?) {
        let transition = MediaZoomTransition(sourceView: sourceView)
        zoomTransition = transition
        transitioningDelegate = transition
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }

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
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        shareButton.configuration?.image = DesignSystem.icon("square.and.arrow.up", pointSize: 16, weight: .semibold)
        shareButton.configuration?.baseForegroundColor = .white
        shareButton.configuration?.background.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        shareButton.configuration?.cornerStyle = .capsule
        shareButton.addAction(UIAction { [weak self] _ in self?.shareCurrent() }, for: .touchUpInside)

        pageControl.numberOfPages = indices.count
        pageControl.currentPage = currentPage
        pageControl.hidesForSinglePage = true
        pageControl.isUserInteractionEnabled = false

        view.addManaged(closeButton)
        view.addManaged(shareButton)
        view.addManaged(pageControl)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
            shareButton.topAnchor.constraint(equalTo: closeButton.topAnchor),
            shareButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            shareButton.widthAnchor.constraint(equalToConstant: 40),
            shareButton.heightAnchor.constraint(equalToConstant: 40),
            pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    private func shareCurrent() {
        let url = AppEnvironment.shared.api.mediaURL(tweetID: tweetID, index: indices[currentPage])
        let visible = collectionView.cellForItem(at: IndexPath(item: currentPage, section: 0)) as? ZoomablePhotoCell
        let items: [Any] = [visible?.image ?? url]
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
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
        cell.load(url: AppEnvironment.shared.api.mediaURL(tweetID: tweetID, index: indices[indexPath.item]), placeholder: seed)
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
        let cell = collectionView.cellForItem(at: IndexPath(item: currentPage, section: 0)) as? ZoomablePhotoCell
        return cell?.isAtMinimumZoom ?? true
    }
}

/// A paging cell hosting a pinch/double-tap zoomable photo loaded at full size.
private final class ZoomablePhotoCell: UICollectionViewCell, UIScrollViewDelegate {
    static let reuseID = "ZoomablePhotoCell"

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var task: Task<Void, Never>?

    var image: UIImage? { imageView.image }
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
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func load(url: URL, placeholder: UIImage? = nil) {
        task?.cancel()
        scrollView.setZoomScale(1, animated: false)
        imageView.image = placeholder
        if placeholder != nil { layoutImage() }
        let bounds = self.bounds.size
        task = Task { [weak self] in
            let loaded = await Self.fullResImage(url, fitting: bounds)
            guard let self, !Task.isCancelled else { return }
            self.imageView.image = loaded
            self.layoutImage()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.zoomScale == scrollView.minimumZoomScale { layoutImage() }
    }

    private func layoutImage() {
        imageView.frame = bounds
        scrollView.contentSize = bounds.size
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let offsetX = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let offsetY = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        imageView.center = CGPoint(x: scrollView.contentSize.width / 2 + offsetX,
                                   y: scrollView.contentSize.height / 2 + offsetY)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

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
    }

    private static func fullResImage(_ url: URL, fitting: CGSize) async -> UIImage? {
        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        return await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.preparingForDisplay()
        }.value
    }
}
