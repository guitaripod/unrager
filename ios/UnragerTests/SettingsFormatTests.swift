import Testing
@testable import Unrager

@Suite("Settings formatting")
struct SettingsFormatTests {
    @Test("A server address shows as host and port without the scheme")
    func host() {
        #expect(SettingsFormat.host(of: "http://100.91.211.44:7777") == "100.91.211.44:7777")
        #expect(SettingsFormat.host(of: "https://unrager.example.com") == "unrager.example.com")
        #expect(SettingsFormat.host(of: "not a url") == "not a url")
    }

    @Test("An empty cache says so, anything else is in file-size units")
    func bytes() {
        #expect(SettingsFormat.bytes(0) == "Empty")
        #expect(SettingsFormat.bytes(280_000).contains("KB"))
    }

    @Test("The tab summary lists the bar in order and leaves Settings out")
    func tabs() {
        #expect(SettingsFormat.tabSummary([.home, .search, .notifications, .settings]) == "Home, Search, Notifications")
    }

    @Test("A typed server address gets http:// when it has no scheme, and only http(s) with a host passes")
    func serverAddress() {
        #expect(SettingsFormat.serverAddress("100.64.0.1:7777")?.absoluteString == "http://100.64.0.1:7777")
        #expect(SettingsFormat.serverAddress("  localhost:7777 ")?.absoluteString == "http://localhost:7777")
        #expect(SettingsFormat.serverAddress("mac.tail.ts.net")?.absoluteString == "http://mac.tail.ts.net")
        #expect(SettingsFormat.serverAddress("https://unrager.example.com")?.absoluteString
            == "https://unrager.example.com")
        #expect(SettingsFormat.serverAddress("HTTP://10.0.0.2:7777")?.host == "10.0.0.2")
        #expect(SettingsFormat.serverAddress("") == nil)
        #expect(SettingsFormat.serverAddress("ftp://10.0.0.2") == nil)
        #expect(SettingsFormat.serverAddress("http://") == nil)
        #expect(SettingsFormat.serverAddress("not a url") == nil)
    }

    @Test("Reset forgets settings but keeps the server, the filter, read markers and recent searches")
    func resetAllowlist() {
        for kept in [
            "unrager.serverURL", "unrager.filterEnabled", "unrager.appearanceMigratedToLocal.v1",
            "unrager.ios.recentSearches", "unrager.notifications.lastSeenID",
            "unrager.notifications.lastSeenTimestamp", "unrager.notifications.deliveredBannerIDs",
        ] {
            #expect(!SettingsReset.clears(kept), "\(kept) should survive a reset")
        }
        for cleared in [
            "unrager.fontScale", "unrager.appearance", "unrager.imagesEnabled", "unrager.postStatsMode",
            "unrager.ios.tabs", "unrager.ios.notificationsFilter", "unrager.notifications.bannersEnabled",
            "unrager.notifications.kind.like", "unrager.postcardTheme",
        ] {
            #expect(SettingsReset.clears(cleared), "\(cleared) should be reset")
        }
        #expect(!SettingsReset.clears("AppleLanguages"))
    }
}
