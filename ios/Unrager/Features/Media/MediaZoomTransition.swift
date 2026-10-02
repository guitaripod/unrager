import UIKit

/// App Store–style zoom: tapped media grows from its thumbnail in the feed into
/// the full-screen viewer and retracts to the thumbnail of the photo being shown
/// when it closes, starting from wherever the viewer's image is at that moment —
/// dragged down or zoomed in. With Reduce Motion on, both directions cross-fade.
/// Held strongly by the presented viewer (the controller's own
/// `transitioningDelegate` is weak).
final class MediaZoomTransition: NSObject, UIViewControllerTransitioningDelegate {
    /// The feed view that shows photo `index`, or nil once it has scrolled away.
    typealias SourceProvider = (Int) -> UIView?

    private let sourceProvider: SourceProvider
    private weak var viewer: MediaViewerViewController?

    init(viewer: MediaViewerViewController, sourceProvider: @escaping SourceProvider) {
        self.viewer = viewer
        self.sourceProvider = sourceProvider
    }

    func animationController(
        forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        ZoomAnimator(presenting: true, viewer: viewer, sourceProvider: sourceProvider)
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        ZoomAnimator(presenting: false, viewer: viewer, sourceProvider: sourceProvider)
    }
}

private final class ZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool
    private weak var viewer: MediaViewerViewController?
    private let sourceProvider: MediaZoomTransition.SourceProvider

    init(presenting: Bool, viewer: MediaViewerViewController?, sourceProvider: @escaping MediaZoomTransition.SourceProvider) {
        self.presenting = presenting
        self.viewer = viewer
        self.sourceProvider = sourceProvider
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        if reduceMotion { return 0.2 }
        return presenting ? 0.42 : 0.3
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        presenting ? present(context) : dismiss(context)
    }

    private func present(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let toView = context.view(forKey: .to) else { context.completeTransition(false); return }
        toView.frame = container.bounds
        container.addSubview(toView)
        toView.layoutIfNeeded()
        toView.alpha = 0

        guard !reduceMotion else {
            UIView.animate(withDuration: transitionDuration(using: context)) {
                toView.alpha = 1
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
            return
        }

        let source = sourceFrame(forPage: viewer?.startPage ?? 0, in: container)
        let snapshot = makeSnapshot(forPage: viewer?.startPage ?? 0)
        snapshot.frame = source
        container.addSubview(snapshot)

        UIView.animate(withDuration: transitionDuration(using: context), delay: 0,
                       usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.curveEaseInOut]) {
            snapshot.frame = self.fittedFrame(aspectOf: source.size, in: container.bounds)
            toView.alpha = 1
        } completion: { _ in
            snapshot.removeFromSuperview()
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    private func dismiss(_ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        guard let fromView = context.view(forKey: .from) else { context.completeTransition(false); return }

        guard !reduceMotion, let viewer, let current = viewer.dismissalGeometry(in: container) else {
            UIView.animate(withDuration: transitionDuration(using: context)) {
                fromView.alpha = 0
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
            return
        }

        let snapshot = UIImageView(image: current.image)
        snapshot.contentMode = .scaleAspectFill
        snapshot.clipsToBounds = true
        snapshot.layer.cornerCurve = .continuous
        snapshot.frame = current.frame
        container.addSubview(snapshot)
        viewer.hidePhotosForTransition()
        let target = sourceFrame(forPage: viewer.page, in: container)

        UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: [.curveEaseInOut]) {
            snapshot.frame = target
            fromView.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    /// The thumbnail's frame in the container, or a centered fallback when the
    /// thumbnail has scrolled away.
    private func sourceFrame(forPage page: Int, in container: UIView) -> CGRect {
        guard let sourceView = sourceProvider(page), let superview = sourceView.superview,
              sourceView.window != nil else {
            let side = min(container.bounds.width, container.bounds.height) * 0.6
            return CGRect(x: container.bounds.midX - side / 2, y: container.bounds.midY - side / 2,
                          width: side, height: side)
        }
        return superview.convert(sourceView.frame, to: container)
    }

    private func fittedFrame(aspectOf size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func makeSnapshot(forPage page: Int) -> UIView {
        if let sourceView = sourceProvider(page), let snapshot = sourceView.snapshotView(afterScreenUpdates: false) {
            snapshot.clipsToBounds = true
            snapshot.layer.cornerCurve = .continuous
            return snapshot
        }
        let placeholder = UIView()
        placeholder.backgroundColor = .black
        return placeholder
    }
}
