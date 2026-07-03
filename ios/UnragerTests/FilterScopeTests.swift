import Testing
@testable import Unrager

@Suite("Rage-filter scope")
struct FilterScopeTests {
    @Test("Collect-then-show gates only the algorithmic Home feeds")
    @MainActor
    func filterScope() {
        #expect(TimelineViewModel(source: .home(following: false, originals: false)).usesFilterCollect)
        #expect(TimelineViewModel(source: .home(following: true, originals: true)).usesFilterCollect)
        #expect(!TimelineViewModel(source: .user(handle: "jack")).usesFilterCollect)
        #expect(!TimelineViewModel(source: .bookmarks(query: "rust")).usesFilterCollect)
        #expect(!TimelineViewModel(source: .search(query: "rust", product: .top)).usesFilterCollect)
        #expect(!TimelineViewModel(source: .mentions).usesFilterCollect)
    }
}
