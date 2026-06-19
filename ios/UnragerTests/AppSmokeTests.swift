import Testing
import UnragerKit
@testable import Unrager

@Suite("App smoke tests")
struct AppSmokeTests {
    @Test("Default server URL is a valid http(s) endpoint")
    func defaultServer() {
        let url = AppSettings.defaultServerURL
        #expect(url.scheme?.hasPrefix("http") == true)
        #expect(url.host != nil)
    }

    @Test("Feed source equality drives reloads")
    func feedSource() {
        #expect(TimelineViewModel.Source.home(following: false, originals: false)
            != .home(following: true, originals: false))
    }

    @Test("Seen tracking is scoped to Following and Mentions")
    @MainActor
    func seenScope() {
        #expect(TimelineViewModel(source: .home(following: true, originals: false)).supportsSeenTracking)
        #expect(TimelineViewModel(source: .mentions).supportsSeenTracking)
        #expect(!TimelineViewModel(source: .home(following: false, originals: false)).supportsSeenTracking)
        #expect(!TimelineViewModel(source: .user(handle: "jack")).supportsSeenTracking)
    }
}
