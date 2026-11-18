import UIKit

/// A navigation controller that lets the screen on top choose the status bar's
/// text colour, so a screen that draws a picture under the bar can ask for
/// light text.
///
/// On iPad it can also hand a push to the second column instead of stacking it:
/// `detailRouter` answers whether it took the screen, so a tap on a post in the
/// feed opens beside it while Settings' own pages keep stacking as they always
/// did.
final class StatusNavigationController: UINavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }

    var detailRouter: ((UIViewController) -> Bool)?

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        if let detailRouter, detailRouter(viewController) { return }
        super.pushViewController(viewController, animated: animated)
    }
}
