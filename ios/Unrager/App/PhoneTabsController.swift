import UIKit

/// The iPhone's own tab bar, wrapped so `RootViewController` can put either it
/// or the iPad's chrome in the same place, and hear about taps the same way.
final class PhoneTabsController: UITabBarController {
    /// A tab was chosen from the bar.
    var onSelect: ((Int) -> Void)?
    /// The tab that was already showing was tapped again.
    var onReselect: ((Int) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        tabBarMinimizeBehavior = .onScrollDown
    }

    override var childForStatusBarStyle: UIViewController? { selectedViewController }

    func setControllers(_ controllers: [UIViewController], selected: Int) {
        viewControllers = controllers
        guard controllers.indices.contains(selected) else { return }
        selectedIndex = selected
    }
}

extension PhoneTabsController: UITabBarControllerDelegate {
    /// A re-tap on the tab already showing: left to the default selection, so
    /// the pop-to-root it performs still happens, and reported for the views
    /// that count re-taps (Home's For You ↔ Following).
    func tabBarController(
        _ tabBarController: UITabBarController, shouldSelect viewController: UIViewController
    ) -> Bool {
        guard viewController === selectedViewController,
              let index = viewControllers?.firstIndex(of: viewController) else { return true }
        onReselect?(index)
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        guard let index = viewControllers?.firstIndex(of: viewController) else { return }
        onSelect?(index)
    }
}
