import XCTest

/// Screenshot walks over the iPad layout, one shape per test: the device is
/// rotated, the app opens on a screen, and each state is attached so a layout
/// change can be looked at instead of guessed at. `ios/scripts/pad-shots.sh`
/// builds these once, runs them, and unpacks the attachments.
final class PadTour: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// A tall window: the tabs belong along the bottom, one column, and a post
    /// opens over the list rather than beside it.
    func testPadPortrait() {
        launch(.portrait, screen: "home")
        snap("01-portrait-feed")
        tapPost(0)
        snap("02-portrait-thread")
    }

    /// Every tab in a tall window: the bar at the bottom, the board above it,
    /// and each screen's own shape.
    func testPadPortraitTabs() {
        launch(.portrait, screen: "home")
        snap("30-portrait-home")
        selectTab("Search", snapAs: "31-portrait-search")
        selectTab("Notifications", snapAs: "32-portrait-notifications")
        selectTab("Settings", snapAs: "33-portrait-settings")
        selectTab("Home", snapAs: "34-portrait-home-again")
        tapPost(0)
        snap("35-portrait-thread")
    }

    /// A wide window: the tabs belong down the side, and a post opens beside
    /// the feed instead of over it.
    func testPadLandscape() {
        launch(.landscapeLeft, screen: "home")
        snap("03-landscape-feed")
        tapPost(0)
        snap("04-landscape-thread")
        tapPost(1)
        snap("05-landscape-next-post")
    }

    /// The other tabs in a wide window: search and notifications beside the
    /// empty column, settings across the window.
    func testPadLandscapeTabs() {
        launch(.landscapeLeft, screen: "home")
        selectTab("Search", snapAs: "07-landscape-search")
        selectTab("Notifications", snapAs: "08-landscape-notifications")
        selectTab("Settings", snapAs: "09-landscape-settings")
    }

    /// The wide window in the dark, where the rail and the glass have to carry
    /// themselves without a page colour underneath.
    func testPadLandscapeDark() {
        launch(.landscapeLeft, screen: "home", appearance: 2)
        snap("10-landscape-dark-feed")
        tapPost(0)
        snap("11-landscape-dark-thread")
    }

    /// The sidebar itself: closed from its own button, reopened from the
    /// navigation bar, and dragged wider.
    func testPadSidebar() {
        launch(.landscapeLeft, screen: "home", sidebarWidth: 248)
        let show = app.buttons["Show sidebar"].firstMatch
        if show.waitForExistence(timeout: 2.5) { show.tap(); pause(1.5) }
        if app.buttons["Hide sidebar"].firstMatch.waitForExistence(timeout: 2) == false {
            app.typeKey("\\", modifierFlags: .command)
            pause(1.5)
        }
        snap("15-sidebar-open")
        let hide = app.buttons["Hide sidebar"].firstMatch
        if hide.waitForExistence(timeout: 4) { hide.tap() } else { XCTFail("no hide button") }
        pause(2)
        snap("16-sidebar-closed")
        app.typeKey("\\", modifierFlags: .command)
        pause(2)
        // The grip is the rail's own last few points, which a 1376-point window
        // puts at about a fifth of its width.
        let grip = app.coordinate(withNormalizedOffset: CGVector(dx: 0.202, dy: 0.6))
        grip.press(forDuration: 0.3, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.285, dy: 0.6)))
        pause(2)
        snap("17-sidebar-wide")
    }

    /// The board: two columns of posts while nothing is open, a single column
    /// beside the post you opened, and the board again once it is closed.
    func testPadBoard() {
        launch(.landscapeLeft, screen: "home")
        snap("18-board")
        tapPost(0)
        snap("19-board-detail")
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 4) { close.tap() } else { XCTFail("no close button") }
        pause(2)
        snap("20-board-again")
    }

    /// The profile tab on a wide window: its header across the top and its
    /// posts as a board below, and the panel floating over them.
    func testPadProfileBoard() {
        launch(.landscapeLeft, screen: "myprofile")
        pause(4)
        snap("26-profile-board")
        tapPost(0)
        snap("27-profile-panel")
    }

    /// Every tab of a profile, and a list of people, on a wide window: posts,
    /// replies and media each use the width, people sit two up.
    func testPadWideTabs() {
        launch(.landscapeLeft, screen: "myprofile")
        pause(4)
        snap("40-profile-posts")
        app.buttons["Replies"].firstMatch.tap()
        pause(4)
        snap("41-profile-replies")
        app.buttons["Media"].firstMatch.tap()
        pause(5)
        snap("42-profile-media")
        launch(.landscapeLeft, screen: "userlist/1001/followers")
        pause(5)
        snap("43-people")
        launch(.landscapeLeft, screen: "notifications")
        pause(4)
        snap("44-notifications-cards")
        tapPost(0)
        pause(4)
        snap("45-notifications-panel")
    }

    /// Settings in a wide window: the rail must still be there, on the root and
    /// on a pushed page.
    func testPadSettingsLandscape() {
        launch(.landscapeLeft, screen: "settings")
        snap("60-settings-landscape")
        launch(.landscapeLeft, screen: "filter")
        snap("61-settings-landscape-page")
    }

    /// Every settings screen in a tall window, where its rows must fit a Mini.
    func testPadSettingsPortrait() {
        launch(.portrait, screen: "settings")
        snap("50-settings")
        launch(.portrait, screen: "filter")
        snap("51-settings-filter")
        launch(.portrait, screen: "notifsettings")
        snap("52-settings-notifications")
        launch(.portrait, screen: "edittabs")
        snap("53-settings-tabs")
        launch(.portrait, screen: "changelog")
        snap("54-settings-changelog")
    }

    /// The bar in the dark, where a strip of the wrong colour shows.
    func testPadDarkPortrait() {
        launch(.portrait, screen: "home", appearance: 2)
        snap("70-dark-home")
        selectTab("Settings", snapAs: "71-dark-settings")
    }

    /// The sidebar's sections: the feeds normally behind the title menu, and the
    /// notification lenses behind the chip bar.
    func testPadSidebarSections() {
        launch(.landscapeLeft, screen: "home")
        snap("23-sidebar-feeds")
        let following = app.buttons["Following"].firstMatch
        if following.waitForExistence(timeout: 3) { following.tap() } else { XCTFail("no Following row") }
        pause(4)
        snap("24-sidebar-following")
        app.buttons["Notifications"].firstMatch.tap()
        pause(2)
        let likes = app.buttons["Likes"].firstMatch
        if likes.waitForExistence(timeout: 3) { likes.tap() } else { XCTFail("no Likes row") }
        pause(4)
        snap("25-sidebar-likes")
    }

    /// A card lifted into the sidebar, caught in flight by stretching the
    /// transition, then the settled thread.
    func testPadPromotion() {
        launch(.landscapeLeft, screen: "home", transitionSeconds: 3)
        let cell = app.cells.element(boundBy: 0)
        guard cell.waitForExistence(timeout: 6) else { XCTFail("no card"); return }
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.11)).tap()
        pause(1.1)
        snap("21-promotion-mid")
        pause(4)
        snap("22-promotion-end")
    }

    /// A window that loses its second column: the thread that was open beside
    /// the feed has to come forward rather than vanish.
    func testPadFold() {
        launch(.landscapeLeft, screen: "home")
        tapPost(0)
        XCUIDevice.shared.orientation = .portrait
        pause(4)
        snap("13-portrait-after-fold")
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(4)
        snap("14-landscape-after-unfold")
    }

    /// What the composer looks like on a wide screen: a centred card, not a
    /// full-height sheet.
    func testPadLandscapeCompose() {
        launch(.landscapeLeft, screen: "compose")
        snap("12-landscape-compose")
    }

    // MARK: - Steps

    private func launch(_ orientation: UIDeviceOrientation, screen: String, appearance: Int = 1,
                        sidebarWidth: Int? = nil, transitionSeconds: Int? = nil) {
        app.launchArguments = [
            "-unrager.serverURL", "http://127.0.0.1:8790",
            "-unrager.filterEnabled", "0",
            "-unrager.postStatsMode", "0",
            "-unrager.appearance", "\(appearance)",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        XCUIDevice.shared.orientation = orientation
        app.launchEnvironment["UNRAGER_SCREEN"] = screen
        if let sidebarWidth { app.launchEnvironment["UNRAGER_PAD_SIDEBAR"] = "\(sidebarWidth)" }
        if let transitionSeconds { app.launchEnvironment["UNRAGER_TRANSITION_SECONDS"] = "\(transitionSeconds)" }
        app.launch()
        pause(9)
    }

    /// Taps a post's own words: a tap on a picture opens the viewer, and one on
    /// the header's blank space is nobody's.
    private func tapPost(_ index: Int) {
        let cell = app.cells.element(boundBy: index)
        guard cell.waitForExistence(timeout: 6) else { return }
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.22)).tap()
        pause(4)
    }

    private func selectTab(_ name: String, snapAs shot: String) {
        let tab = app.buttons[name].firstMatch
        guard tab.waitForExistence(timeout: 4) else {
            XCTFail("no \(name) tab in the rail")
            return
        }
        tab.tap()
        pause(4)
        snap(shot)
    }

    /// Turns the simulator on its side and holds it there for
    /// `UNRAGER_HOLD_SECONDS` (default ten minutes), launching nothing, so real
    /// windows can be tiled and resized by hand or with `axe` in landscape —
    /// the one shape a simulator can't be put in from the command line.
    func testHoldLandscape() {
        let seconds = Double(ProcessInfo.processInfo.environment["UNRAGER_HOLD_SECONDS"] ?? "") ?? 600
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(seconds)
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
