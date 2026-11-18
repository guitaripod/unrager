import UIKit

/// Settings on an iPad: the sections are the split view's own sidebar and the
/// chosen one's rows are its secondary column, so the system provides the
/// column widths, the toggle, the collapse to one column and the transitions.
final class SettingsSplitViewController: UISplitViewController {
    private let rows = SettingsViewController()
    private let index: SettingsIndexViewController

    init() {
        index = SettingsIndexViewController()
        super.init(style: .doubleColumn)
        rows.standsAlone = false
        index.onChoose = { [weak self] section in
            guard let self, section != self.rows.chosen else { return }
            self.rows.chosen = section
            self.index.mark(section)
            self.show(.secondary)
        }
        rows.onStateChange = { [weak self] in
            guard let self else { return }
            self.index.refresh(summaries: self.indexSummaries())
            self.index.mark(self.rows.chosen)
            self.title = self.rows.chosen.indexTitle
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredDisplayMode = .oneBesideSecondary
        preferredPrimaryColumnWidth = 288
        minimumPrimaryColumnWidth = 220
        maximumPrimaryColumnWidth = 360
        presentsWithGesture = true
        delegate = self

        let side = UINavigationController(rootViewController: index)
        let main = UINavigationController(rootViewController: rows)
        setViewController(side, for: .primary)
        setViewController(main, for: .secondary)
        index.mark(rows.chosen)
        title = rows.chosen.indexTitle
        rows.navigationItem.largeTitleDisplayMode = .never
    }

    /// Pushes one of the settings pages into the rows column.
    func push(_ page: UIViewController) {
        (viewController(for: .secondary) as? UINavigationController)?.pushViewController(page, animated: true)
    }

    /// Where the app's own rail has just opened a settings page from.
    var rowsNavigation: UINavigationController? {
        viewController(for: .secondary) as? UINavigationController
    }

    private func indexSummaries() -> [SettingsViewController.Section: String] {
        var summaries: [SettingsViewController.Section: String] = [:]
        for section in SettingsViewController.Section.allCases {
            summaries[section] = rows.summary(of: section)
        }
        return summaries
    }
}

extension SettingsSplitViewController: UISplitViewControllerDelegate {
    /// Tapping a section on a narrow window slides its rows in, the way the
    /// system's own settings do.
    func splitViewController(
        _ splitViewController: UISplitViewController, collapseSecondary secondaryViewController: UIViewController,
        onto primaryViewController: UIViewController
    ) -> Bool {
        false
    }
}
