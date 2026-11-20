import UIKit

/// How a post opens and closes: the platform's own way on every device.
///
/// On an iPad board the card a person tapped zooms into the post and the post
/// zooms back into that card when it closes — by Back, by a swipe in from the
/// leading edge, or by pulling it down — the way Photos and the App Store open
/// what is picked from a grid. In a list, on the phone and wherever no card is
/// on screen, it is a page pushed like any other, which the whole screen swipes
/// back from. Either way it lives on the tab's own stack, so the board or the
/// list waits underneath with its place kept.
@MainActor
enum PostOpening {
    /// Pushes `page` onto `navigation`, zooming out of the view `source` names
    /// when it names one. `source` is asked again as the page closes, so a card
    /// that scrolled out of the board in the meantime is simply not zoomed into.
    static func open(_ page: UIViewController, on navigation: UINavigationController?,
                     zoomingFrom source: (() -> UIView?)? = nil) {
        guard let navigation else { return }
        if let source {
            page.preferredTransition = .zoom { _ in source() }
        }
        navigation.pushViewController(page, animated: true)
    }
}
