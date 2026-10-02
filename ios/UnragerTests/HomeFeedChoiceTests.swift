import Testing
@testable import Unrager

@Suite("Home title menu")
struct HomeFeedChoiceTests {
    @Test("Each Home source maps to the menu entry that marks it active")
    func activeChoice() {
        #expect(HomeFeedChoice(source: .home(following: false, originals: true)) == .forYou)
        #expect(HomeFeedChoice(source: .home(following: true, originals: false)) == .following)
        #expect(HomeFeedChoice(source: .mentions) == .mentions)
        #expect(HomeFeedChoice(source: .bookmarks(query: "swift")) == .bookmarks)
        #expect(HomeFeedChoice(source: .user(handle: "mirakoski")) == nil)
    }

    @Test("A keyword-filtered Bookmarks list names its keyword")
    func bookmarksTitle() {
        #expect(HomeFeedChoice.title(for: .bookmarks(query: "")) == "Bookmarks")
        #expect(HomeFeedChoice.title(for: .bookmarks(query: "  \n")) == "Bookmarks")
        #expect(HomeFeedChoice.title(for: .bookmarks(query: " rust ")) == "Bookmarks · \u{201C}rust\u{201D}")
        #expect(HomeFeedChoice.title(for: .home(following: true, originals: false)) == "Following")
        #expect(HomeFeedChoice.title(for: .search(query: "x", product: .top)) == "Home")
    }

    @Test("A long keyword is truncated with an ellipsis")
    func longKeyword() {
        let title = HomeFeedChoice.title(for: .bookmarks(query: String(repeating: "a", count: 40)))
        let shown = String(repeating: "a", count: HomeFeedChoice.keywordLimit - 1) + "…"
        #expect(title == "Bookmarks · \u{201C}\(shown)\u{201D}")
        let exact = String(repeating: "b", count: HomeFeedChoice.keywordLimit)
        #expect(HomeFeedChoice.title(for: .bookmarks(query: exact)) == "Bookmarks · \u{201C}\(exact)\u{201D}")
    }
}
