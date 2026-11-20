import UIKit

extension UIViewController {
    /// Whether this screen, or the screen holding it, is the first on its
    /// navigation stack. Only there does a rightward swipe have nothing to go
    /// back to: on any page above it the swipe belongs to the system's way
    /// back, from the edge or from anywhere across the page, so a row's
    /// leading swipe action there would like a post the reader meant to leave.
    var isAtRootOfStack: Bool {
        guard let navigation = navigationController else { return true }
        var current: UIViewController = self
        while let parent = current.parent, parent !== navigation { current = parent }
        return navigation.viewControllers.first === current
    }
}
