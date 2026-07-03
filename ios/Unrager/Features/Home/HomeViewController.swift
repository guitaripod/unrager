import UIKit
import UnragerKit

/// Home feed with source switching (For You / Following / Mentions / Bookmarks),
/// an Originals toggle, and a floating Liquid-Glass compose button.
final class HomeViewController: FeedViewController {
    private var following = false
    private var originals = false
    private var chronological = false
    private let titleButton = UIButton(type: .system)

    /// The Home tab reopens on whatever mode it was last left on
    /// (`ClientSettings.homeFollowing`); Originals is restored too. Local state
    /// is authoritative — the feed loads from it immediately, with no wait for
    /// the server session.
    init() {
        let restoredFollowing = ClientSettings.homeFollowing
        let restoredOriginals = ClientSettings.homeOriginals
        following = restoredFollowing
        originals = restoredOriginals
        chronological = ClientSettings.followingChronological
        super.init(viewModel: TimelineViewModel(source: .home(following: restoredFollowing, originals: restoredOriginals)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureTitleMenu()
        configureNavItems()
        configureComposeButton()
        updateTabBarItem()
        setChronologicalSort(chronological && following)
    }

    /// The title rides as a *leading* bar item (X's own pattern), so its
    /// position never jumps when the trailing cluster changes between modes.
    /// The nav item's own title is blanked — the tab is titled "Home", which
    /// would otherwise render redundantly in the centre.
    private func configureTitleMenu() {
        navigationItem.title = ""
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: titleButton)
        updateTitle()
    }

    private lazy var filterButton = UIBarButtonItem(
        image: DesignSystem.icon("line.3.horizontal.decrease.circle"), menu: filterMenu())

    private func configureNavItems() {
        refreshRightBarItems()
    }

    /// One trailing menu button carries both feed filters — Originals and (on
    /// Following) the chronological sort — so the bar holds at most two
    /// trailing items and the header never crowds or lurches on a mode switch.
    private func filterMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: "Originals only", image: DesignSystem.icon("line.3.horizontal.decrease"),
                     state: originals ? .on : .off) { [weak self] _ in self?.toggleOriginals() },
        ]
        if following {
            children.append(UIAction(title: "Chronological order", image: DesignSystem.icon("clock"),
                                     state: chronological ? .on : .off) { [weak self] _ in self?.toggleChronological() })
        }
        return UIMenu(children: children)
    }

    private func refreshRightBarItems() {
        filterButton.menu = filterMenu()
        let filterActive = originals || (chronological && following)
        filterButton.image = DesignSystem.icon(
            filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        navigationItem.rightBarButtonItems = [filterButton, unreadBarButton].compactMap { $0 }
    }

    private func updateTitle() {
        let name: String
        switch viewModel.source {
        case let .home(following, _): name = following ? "Following" : "For You"
        case .mentions: name = "Mentions"
        case .bookmarks: name = "Bookmarks"
        default: name = "Home"
        }
        titleButton.menu = sourceMenu()
        titleButton.showsMenuAsPrimaryAction = true
        var config = UIButton.Configuration.plain()
        config.title = name
        config.image = DesignSystem.icon("chevron.down", pointSize: 12, weight: .semibold)
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = DesignSystem.Color.label
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = DesignSystem.Typography.name()
            return out
        }
        titleButton.configuration = config
        titleButton.titleLabel?.numberOfLines = 1
        titleButton.titleLabel?.lineBreakMode = .byTruncatingTail
        titleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func sourceMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "For You", image: DesignSystem.icon("sparkles")) { [weak self] _ in
                self?.switchHome(following: false)
            },
            UIAction(title: "Following", image: DesignSystem.icon("person.2")) { [weak self] _ in
                self?.switchHome(following: true)
            },
            UIAction(title: "Mentions", image: DesignSystem.icon("at")) { [weak self] _ in
                self?.viewModel.updateSource(.mentions); self?.afterSwitch()
            },
            UIAction(title: "Bookmarks", image: DesignSystem.icon("bookmark")) { [weak self] _ in
                self?.promptBookmarks()
            },
        ])
    }

    private func promptBookmarks() {
        let alert = UIAlertController(
            title: "Search Bookmarks",
            message: "X searches bookmarks by keyword — there's no \"all\" listing.",
            preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "keyword"
            $0.autocapitalizationType = .none
            $0.returnKeyType = .search
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Search", style: .default) { [weak self] _ in
            let query = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else { return }
            self?.viewModel.updateSource(.bookmarks(query: query))
            self?.afterSwitch()
        })
        present(alert, animated: true)
    }

    private func switchHome(following: Bool, persist: Bool = true) {
        self.following = following
        if persist { ClientSettings.homeFollowing = following }
        viewModel.updateSource(.home(following: following, originals: originals))
        setChronologicalSort(chronological && following)
        updateTabBarItem()
        afterSwitch()
    }

    /// Flips For You ↔ Following — bound to a double-tap on the Home tab.
    func toggleFeedMode() {
        Haptics.selection()
        switchHome(following: !following)
    }

    #if DEBUG
    /// Screenshot router entry point: jump straight to the Following feed
    /// without persisting the mode, so a QA run can't contaminate later runs
    /// (or the user's real preference).
    func debugSwitchToFollowing() { switchHome(following: true, persist: false) }
    #endif

    private func toggleOriginals() {
        originals.toggle()
        ClientSettings.homeOriginals = originals
        Haptics.selection()
        if case .home = viewModel.source {
            viewModel.updateSource(.home(following: following, originals: originals))
        }
        refreshRightBarItems()
    }

    /// Toggles strict newest-first ordering of the Following feed.
    private func toggleChronological() {
        chronological.toggle()
        ClientSettings.followingChronological = chronological
        Haptics.selection()
        setChronologicalSort(chronological && following)
        refreshRightBarItems()
    }

    /// Mirrors the live feed mode onto the tab bar so the Home tab reads
    /// "Following" (not "For You") while in Following mode, and vice versa.
    private func updateTabBarItem() {
        let title = following ? "Following" : "For You"
        let image = DesignSystem.icon(following ? "person.2.fill" : "sparkles")
        tabBarItem.title = title
        tabBarItem.image = image
        navigationController?.tabBarItem.title = title
        navigationController?.tabBarItem.image = image
    }

    private func afterSwitch() {
        updateTitle()
        refreshRightBarItems()
        collectionView.setContentOffset(.zero, animated: false)
    }

    private func configureComposeButton() {
        var config = UIButton.Configuration.unragerProminentGlass()
        config.image = DesignSystem.icon("square.and.pencil", pointSize: 20, weight: .semibold)
        let button = UIButton(configuration: config)
        button.setConcentricCorners(minimum: 28)
        button.addAction(UIAction { [weak self] _ in self?.presentCompose() }, for: .touchUpInside)
        view.addManaged(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -DesignSystem.Spacing.l),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -DesignSystem.Spacing.l),
            button.widthAnchor.constraint(equalToConstant: 56),
            button.heightAnchor.constraint(equalToConstant: 56),
        ])
    }

    private func presentCompose() {
        let compose = ComposeViewController(mode: .new)
        present(UINavigationController(rootViewController: compose), animated: true)
    }
}
