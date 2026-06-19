import AppKit
import UnragerKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.info("macOS app launched, server=\(AppSettings.serverURL.absoluteString)", category: .app)
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let controller = MainWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController = controller
        controller.attachNotificationService()
        NotificationCenterService.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menu bar

    private func buildMenu() {
        let mainMenu = NSMenu()

        mainMenu.addItem(appMenu())
        mainMenu.addItem(fileMenu())
        mainMenu.addItem(editMenu())
        mainMenu.addItem(tweetMenu())
        mainMenu.addItem(viewMenu())
        mainMenu.addItem(windowMenu())

        NSApp.mainMenu = mainMenu
    }

    private func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Unrager")
        menu.addItem(withTitle: "About Unrager", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(MainWindowController.openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Unrager", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Quit Unrager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        let compose = menu.addItem(withTitle: "New Tweet", action: #selector(MainWindowController.newCompose), keyEquivalent: "n")
        compose.keyEquivalentModifierMask = [.command]
        let refresh = menu.addItem(withTitle: "Refresh", action: #selector(MainWindowController.refresh), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item.submenu = menu
        return item
    }

    private func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let find = menu.addItem(withTitle: "Search", action: #selector(MainWindowController.selectSearch), keyEquivalent: "f")
        find.keyEquivalentModifierMask = [.command]
        item.submenu = menu
        return item
    }

    private func tweetMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Tweet")
        let open = menu.addItem(withTitle: "Open Thread", action: #selector(MainWindowController.openSelectedThread), keyEquivalent: "\r")
        open.keyEquivalentModifierMask = []
        let like = menu.addItem(withTitle: "Like", action: #selector(MainWindowController.likeSelected), keyEquivalent: "l")
        like.keyEquivalentModifierMask = [.command]
        let reply = menu.addItem(withTitle: "Reply", action: #selector(MainWindowController.replySelected), keyEquivalent: "r")
        reply.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        let ask = menu.addItem(withTitle: "Ask (Explain)", action: #selector(MainWindowController.askSelected), keyEquivalent: "e")
        ask.keyEquivalentModifierMask = [.command, .shift]
        let translate = menu.addItem(withTitle: "Translate", action: #selector(MainWindowController.translateSelected), keyEquivalent: "t")
        translate.keyEquivalentModifierMask = [.command, .shift]
        item.submenu = menu
        return item
    }

    private func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        addSourceItem(menu, title: "For You", action: #selector(MainWindowController.selectForYou), key: "1")
        addSourceItem(menu, title: "Following", action: #selector(MainWindowController.selectFollowing), key: "2")
        addSourceItem(menu, title: "Mentions", action: #selector(MainWindowController.selectMentions), key: "3")
        addSourceItem(menu, title: "Bookmarks", action: #selector(MainWindowController.selectBookmarks), key: "4")
        menu.addItem(.separator())
        let notifications = menu.addItem(withTitle: "Notifications", action: #selector(MainWindowController.selectNotifications), keyEquivalent: "5")
        notifications.keyEquivalentModifierMask = [.command]
        let myProfile = menu.addItem(withTitle: "My Profile", action: #selector(MainWindowController.openMyProfile), keyEquivalent: "6")
        myProfile.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        let originals = menu.addItem(withTitle: "Originals Only", action: #selector(MainWindowController.toggleOriginals), keyEquivalent: "o")
        originals.keyEquivalentModifierMask = [.command, .control]
        let back = menu.addItem(withTitle: "Back", action: #selector(MainWindowController.goBack), keyEquivalent: "[")
        back.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        let sidebar = menu.addItem(withTitle: "Toggle Sidebar", action: #selector(MainWindowController.toggleSidebar), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        item.submenu = menu
        return item
    }

    private func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        item.submenu = menu
        return item
    }

    private func addSourceItem(_ menu: NSMenu, title: String, action: Selector, key: String) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command]
    }
}
