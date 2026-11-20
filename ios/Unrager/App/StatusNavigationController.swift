import UIKit

/// A navigation controller that lets the screen on top choose the status bar's
/// text colour, so a screen that draws a picture under the bar can ask for
/// light text.
final class StatusNavigationController: UINavigationController {
    override var childForStatusBarStyle: UIViewController? { topViewController }
}
