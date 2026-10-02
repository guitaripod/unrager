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
}
