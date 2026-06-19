import UIKit

/// App Store–style zoom: tapped media grows from its thumbnail in the feed into
/// the full-screen viewer and retracts back to it on dismiss. A snapshot of the
/// source view animates to/from the screen-centered aspect-fit frame while the
/// viewer fades under it. Held strongly by the presented viewer (the controller's
/// own `transitioningDelegate` is weak).
final class MediaZoomTransition: NSObject, UIViewControllerTransitioningDelegate {
    private weak var sourceView: UIView?

    init(sourceView: UIView?) {
        self.sourceView = sourceView
    }

    func animationController(
        forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        ZoomAnimator(presenting: true, sourceView: sourceView)
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        ZoomAnimator(presenting: false, sourceView: sourceView)
    }
}

private final class ZoomAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool
    private weak var sourceView: UIView?

    init(presenting: Bool, sourceView: UIView?) {
        self.presenting = presenting
        self.sourceView = sourceView
    }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        presenting ? 0.42 : 0.3
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

        let source = sourceFrame(in: container)
        let snapshot = makeSnapshot()
        snapshot.frame = source
        container.addSubview(snapshot)
        toView.alpha = 0

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
        let source = sourceFrame(in: container)
        let snapshot = makeSnapshot()
        snapshot.frame = fittedFrame(aspectOf: source.size, in: container.bounds)
        container.addSubview(snapshot)

        UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: [.curveEaseInOut]) {
            snapshot.frame = source
            fromView.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
            context.completeTransition(!context.transitionWasCancelled)
        }
    }

    /// The source thumbnail's frame in the container, or a centered fallback when
    /// the source has scrolled away.
    private func sourceFrame(in container: UIView) -> CGRect {
        guard let sourceView, let superview = sourceView.superview, sourceView.window != nil else {
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

    private func makeSnapshot() -> UIView {
        if let sourceView, let snapshot = sourceView.snapshotView(afterScreenUpdates: false) {
            snapshot.clipsToBounds = true
            snapshot.layer.cornerCurve = .continuous
            return snapshot
        }
        let placeholder = UIView()
        placeholder.backgroundColor = .black
        return placeholder
    }
}
