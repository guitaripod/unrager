import UIKit

/// The iPad menu bar, revealed by a swipe from the top or the pointer. Built
/// once at launch and rebuilt when the tabs change. Items stay put and dim
/// when they don't apply, so the bar is the same shape every time it's opened.
enum AppMenu {
    @MainActor
    static func install() {
        let configuration = UIMainMenuSystem.Configuration()
        configuration.printingPreference = .removed
        configuration.inspectorPreference = .removed
        configuration.documentPreference = .removed
        configuration.findingPreference = .removed
        configuration.newScenePreference = .removed
        configuration.sidebarPreference = .included
        UIMainMenuSystem.shared.setBuildConfiguration(configuration) { builder in
            build(builder)
        }
    }

    @MainActor
    static func rebuild() {
        UIMainMenuSystem.shared.setNeedsRebuild()
    }

    @MainActor
    private static func build(_ builder: any UIMenuBuilder) {
        builder.insertChild(viewActions(), atStartOfMenu: .view)
        builder.insertChild(tabMenu(), atStartOfMenu: .view)
        builder.insertChild(newPostMenu(), atStartOfMenu: .newItem)
    }

    @MainActor
    private static func newPostMenu() -> UIMenu {
        UIMenu(options: .displayInline, children: [
            command("New Post", symbol: "square.and.pencil", action: #selector(RootViewController.newTweetCommand), input: "n"),
        ])
    }

    @MainActor
    private static func tabMenu() -> UIMenu {
        let tabs = ClientSettings.tabs.enumerated().map { index, tab in
            command(
                tab.title, symbol: tab.symbol,
                action: #selector(RootViewController.selectTabCommand(_:)),
                input: "\(index + 1)", slot: index + 1)
        }
        return UIMenu(options: .displayInline, children: tabs)
    }

    @MainActor
    private static func viewActions() -> UIMenu {
        UIMenu(options: .displayInline, children: [
            command("Refresh", symbol: "arrow.clockwise", action: #selector(RootViewController.refreshCommand), input: "r", repeats: true),
            command("Search", symbol: "magnifyingglass", action: #selector(RootViewController.searchCommand), input: "f"),
            command("Toggle Sidebar", symbol: "sidebar.leading", action: #selector(RootViewController.toggleSidebarCommand), input: "\\"),
        ])
    }

    @MainActor
    private static func command(
        _ title: String, symbol: String, action: Selector, input: String,
        repeats: Bool = false, slot: Int? = nil
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            title: title, image: UIImage(systemName: symbol), action: action, input: input,
            modifierFlags: .command, propertyList: slot.map { NSNumber(value: $0) })
        command.wantsPriorityOverSystemBehavior = true
        command.repeatBehavior = repeats ? .repeatable : .nonRepeatable
        return command
    }
}
