import Testing
@testable import Unrager

@Suite("Tab item catalog")
struct TabItemTests {
    @Test("Legacy For You / Following persistence folds into the single Home tab")
    func legacyMigration() {
        #expect(TabItem.resolve(persisted: "forYou") == .home)
        #expect(TabItem.resolve(persisted: "following") == .home)
        #expect(TabItem.resolve(persisted: "search") == .search)
        #expect(TabItem.resolve(persisted: "bogus") == nil)
    }

    @Test("Sanitized selections are unique, capped and never empty")
    func sanitize() {
        #expect(TabItem.sanitized([.home, .home, .search]) == [.home, .search])
        #expect(TabItem.sanitized([]) == TabItem.defaults)
        #expect(TabItem.sanitized([.home, .search, .notifications, .mentions, .bookmarks, .settings]).count
            == TabItem.maxCount)
    }

    @Test("Only Home carries an Edit Tabs subtitle")
    func subtitles() {
        #expect(TabItem.home.subtitle != nil)
        for tab in TabItem.allCases where tab != .home {
            #expect(tab.subtitle == nil)
        }
    }
}
