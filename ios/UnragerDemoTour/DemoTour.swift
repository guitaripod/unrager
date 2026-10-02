import XCTest

/// Scripted walks through the app for the demo video. Each scene launches the
/// app against the mock server (`demos/app/mock_server.py`), then acts like a
/// person using it, with pauses a viewer can follow. `demos/app/record.sh`
/// records the simulator around each scene.
final class DemoTour: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = [
            "-unrager.serverURL", "http://127.0.0.1:8790",
            "-unrager.filterEnabled", "1",
            "-unrager.postStatsMode", "0",
            "-unrager.appearance", "1",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
    }

    // MARK: - Scenes

    /// The feed: it opens, fills, and scrolls past a photo, a pair of portraits,
    /// a vertical video and a long post.
    func testScene01Feed() {
        launchFromHomeScreen()
        pause(2.5)
        scroll(by: 380, seconds: 1.6)
        pause(1.2)
        scroll(by: 520, seconds: 1.8)
        pause(1.4)
        scroll(by: 520, seconds: 1.8)
        pause(1.2)
        scroll(by: 560, seconds: 2.0)
        pause(2.2)
        scroll(by: 520, seconds: 1.8)
        pause(2.0)
    }

    /// The rage filter: its menu, what it hid and why, and showing one anyway.
    func testScene02Filter() {
        launch()
        pause(2.0)
        app.navigationBars.buttons["filter"].firstMatch.tap()
        pause(1.6)
        let hidden = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Hidden posts'")).firstMatch
        if hidden.waitForExistence(timeout: 3) { hidden.tap() }
        pause(2.6)
        let firstRow = app.cells.firstMatch
        if firstRow.waitForExistence(timeout: 3) {
            firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            pause(2.2)
        }
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        pause(2.0)
    }

    /// A touch and hold on the compose button.
    func testScene03ComposeMenu() {
        launch()
        pause(2.5)
        app.buttons["Compose"].press(forDuration: 1.1)
        pause(3.4)
    }

    /// The stats strip: public figures on someone's post, X's own on yours.
    func testScene04Stats() {
        launch()
        pause(1.8)
        let fieldNotes = app.cells.matching(NSPredicate(format: "label CONTAINS 'Field Notes'")).firstMatch
        let views = fieldNotes.buttons.matching(NSPredicate(format: "label ENDSWITH 'views'")).firstMatch
        if views.waitForExistence(timeout: 4) { views.tap() }
        pause(2.6)
        scroll(by: 560, seconds: 1.6)
        pause(0.8)
        let mine = app.cells.matching(NSPredicate(format: "label CONTAINS 'Nora Lind'")).firstMatch
        scrollUntilVisible(mine)
        let myViews = mine.buttons.matching(NSPredicate(format: "label ENDSWITH 'views'")).firstMatch
        if myViews.waitForExistence(timeout: 3) { myViews.tap() }
        pause(3.2)
    }

    /// A thread: replies under their parents, and who else a reply answers.
    func testScene05Thread() {
        launch()
        pause(1.6)
        let mira = app.cells.matching(NSPredicate(format: "label CONTAINS 'Two directions'")).firstMatch
        scrollUntilVisible(mira)
        mira.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        pause(2.4)
        scroll(by: 420, seconds: 1.8)
        pause(1.2)
        scroll(by: 420, seconds: 1.8)
        pause(2.0)
    }

    /// A profile: the header image moving with the scroll.
    func testScene06Profile() {
        launch()
        pause(1.6)
        let mira = app.cells.matching(NSPredicate(format: "label CONTAINS 'Two directions'")).firstMatch
        scrollUntilVisible(mira)
        mira.buttons["Mira Koski, profile"].firstMatch.tap()
        pause(2.6)
        scroll(by: 300, seconds: 1.8)
        pause(0.8)
        scroll(by: -300, seconds: 1.4)
        pause(0.6)
        pullDown()
        pause(1.2)
    }

    /// Ask, from a post's menu.
    func testScene07Ask() {
        launch()
        pause(1.6)
        let physics = app.cells.matching(NSPredicate(format: "label CONTAINS 'Why is the sky blue'")).firstMatch
        scrollUntilVisible(physics)
        physics.press(forDuration: 1.0)
        pause(1.8)
        let ask = app.buttons["Ask"].firstMatch
        if ask.waitForExistence(timeout: 3) { ask.tap() }
        pause(1.2)
        let explain = app.buttons["Explain"].firstMatch
        if explain.waitForExistence(timeout: 3) { explain.tap() }
        pause(6.0)
    }

    /// Settings, and the app in the dark.
    func testScene08Settings() {
        launch()
        pause(1.6)
        app.tabBars.buttons["Settings"].tap()
        pause(2.4)
        scroll(by: 520, seconds: 1.8)
        pause(1.2)
        scroll(by: 420, seconds: 1.6)
        pause(1.6)
    }


    // MARK: - Notifications

    /// The list: New with its digest, then Today, Yesterday and the week, a long
    /// way down and back.
    func testScene09NotifList() {
        launchNotifications()
        pause(3.2)
        scroll(by: 560, seconds: 2.4)
        pause(1.4)
        scroll(by: 640, seconds: 2.4)
        pause(1.4)
        scroll(by: 640, seconds: 2.4)
        pause(1.6)
        scroll(by: 640, seconds: 2.4)
        pause(1.2)
        scroll(by: -2400, seconds: 1.2)
        pause(1.6)
    }

    /// The filter chips: likes, reposts, follows, and mentions as full posts.
    func testScene10NotifChips() {
        launchNotifications()
        pause(2.4)
        tapChip("Likes")
        pause(2.6)
        tapChip("Reposts")
        pause(2.0)
        tapChip("Follows")
        pause(2.6)
        tapChip("Mentions")
        pause(3.0)
        tapChip("All")
        pause(2.4)
    }

    /// What a row lets you do: follow back, see everyone behind a group, the
    /// long-press menu, and read it all.
    func testScene11NotifActions() {
        launchNotifications()
        pause(2.4)
        let followBack = app.buttons["Follow back"].firstMatch
        if followBack.waitForExistence(timeout: 3) { followBack.tap() }
        pause(2.4)
        let first = app.cells.firstMatch
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.11, dy: 0.25)).tap()
        pause(2.6)
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        pause(1.2)
        let second = app.cells.element(boundBy: 1)
        second.press(forDuration: 1.1)
        pause(2.8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        pause(1.2)
        let markRead = app.buttons["Mark all read"].firstMatch
        if markRead.waitForExistence(timeout: 3) { markRead.tap() }
        pause(3.4)
    }

    /// Arrivals: new activity lands while the list is open and glows in; with
    /// the reader scrolled away, a pill waits to take them back to the top.
    func testScene12NotifLive() {
        launchNotifications(pollSeconds: 3)
        pause(2.6)
        inject(type: "Reply", handle: "tomasbuilds", text: "Wait, you shipped it already? Looks great.")
        pause(5.0)
        scroll(by: 760, seconds: 1.8)
        pause(1.0)
        inject(type: "Mention", handle: "lenapark", text: "@noralind the new notifications are lovely")
        inject(type: "Like", handle: "orbitaldaily", text: "", others: "27")
        pause(6.0)
        let pill = app.buttons.matching(NSPredicate(format: "label CONTAINS 'new notifications'")).firstMatch
        if pill.waitForExistence(timeout: 3) { pill.tap() }
        pause(3.6)
    }

    // MARK: - Moves

    private func launch() {
        app.launch()
    }

    /// Starts from the Home Screen, so the recording opens with the app coming
    /// up from its icon.
    private func launchFromHomeScreen() {
        XCUIDevice.shared.press(.home)
        pause(1.2)
        app.launch()
    }


    /// Opens the app on its Notifications tab (the mock server says the last
    /// visit was a hundred minutes back, so the newest activity reads as
    /// unread), with polling fast enough that an arrival doesn't keep a viewer
    /// waiting.
    private func launchNotifications(pollSeconds: Int = 15) {
        app.launchEnvironment["UNRAGER_POLL_SECONDS"] = String(pollSeconds)
        launchFromHomeScreen()
        pause(1.6)
        app.tabBars.buttons["Notifications"].tap()
    }

    private func tapChip(_ title: String) {
        let chip = app.buttons[title].firstMatch
        if chip.waitForExistence(timeout: 3) { chip.tap() }
    }

    /// Has the mock server add a notification that arrives now.
    private func inject(type: String, handle: String, text: String, others: String? = nil) {
        var components = URLComponents(string: "http://127.0.0.1:8790/__inject")!
        components.queryItems = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "handle", value: handle),
                                 URLQueryItem(name: "text", value: text)]
        if let others { components.queryItems?.append(URLQueryItem(name: "others", value: others)) }
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: components.url!) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 5)
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Drags the list up by `points` over `seconds` (negative: down), the way a
    /// thumb would, ending with a small settle.
    private func scroll(by points: CGFloat, seconds: Double) {
        let screen = app.windows.firstMatch.frame
        let x = screen.width * 0.5
        let startY = points > 0 ? screen.height * 0.72 : screen.height * 0.30
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: startY))
        let end = start.withOffset(CGVector(dx: 0, dy: -points))
        let velocity = XCUIGestureVelocity(rawValue: max(80, abs(points) / seconds))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0.05)
    }

    private func pullDown() {
        let screen = app.windows.firstMatch.frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: screen.width * 0.5, dy: screen.height * 0.35))
        let end = start.withOffset(CGVector(dx: 0, dy: screen.height * 0.22))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 260), thenHoldForDuration: 0.9)
    }

    private func scrollUntilVisible(_ element: XCUIElement, attempts: Int = 14) {
        var tries = 0
        while !(element.exists && element.isHittable) && tries < attempts {
            scroll(by: 380, seconds: 0.9)
            pause(0.3)
            tries += 1
        }
    }
}
