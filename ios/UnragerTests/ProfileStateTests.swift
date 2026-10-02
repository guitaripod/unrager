import Foundation
import Testing
import UIKit
import UnragerKit
@testable import Unrager

@Suite("Profile load state")
struct ProfileLoadStateTests {
    @Test("An account X won't show is final, with the reason in words and no Retry")
    func goneAccountsAreFinal() {
        let cases: [(APIError, String)] = [
            (.unavailable(reason: "suspended", message: "x"), "This account is suspended."),
            (.unavailable(reason: "protected", message: "x"), "This account is protected."),
            (.unavailable(reason: "deleted", message: "x"), "This account doesn't exist."),
            (.unavailable(reason: "deactivated", message: "x"), "This account doesn't exist."),
            (.unavailable(reason: nil, message: "HTTP 410"), "This account isn't available."),
            (.unavailable(reason: "something new", message: "x"), "This account isn't available."),
            (.notFound("no such user"), "This account doesn't exist."),
        ]
        for (error, message) in cases {
            let state = ProfileLoadState.failure(error)
            #expect(state == .gone(message: message))
            #expect(state.isFinal)
            #expect(!state.offersRetry)
            #expect(state.message == message)
        }
    }

    @Test("A rate limit says how long to wait and offers Retry")
    func rateLimitOffersRetry() {
        let state = ProfileLoadState.failure(APIError.rateLimited("slow down", retryAfter: 240))
        #expect(state == .failed(message: "X is rate-limiting requests. Try again in 4 min."))
        #expect(state.offersRetry)
        #expect(!state.isFinal)
    }

    @Test("Any other failure keeps the generic message and Retry")
    func otherFailuresRetry() {
        for error in [APIError.timeout, .offline("down"), .server(status: 500, message: "boom")] as [Error] {
            let state = ProfileLoadState.failure(error)
            #expect(state == .failed(message: "Couldn't load this profile."))
            #expect(state.offersRetry)
        }
        #expect(ProfileLoadState.failure(URLError(.notConnectedToInternet)).offersRetry)
    }

    @Test("Loading and loaded say nothing in the account's place")
    func settledStatesHaveNoMessage() {
        #expect(ProfileLoadState.loading.message == nil)
        #expect(ProfileLoadState.loaded.message == nil)
        #expect(!ProfileLoadState.loaded.offersRetry)
    }
}

private struct Refused: Error {}

@MainActor
@Suite("Profile mute and block")
struct ProfileModerationTests {
    @Test("Menu titles follow the current state")
    func titles() {
        #expect(ProfileModeration.title(for: .mute, isOn: false, handle: "kit") == "Mute @kit")
        #expect(ProfileModeration.title(for: .mute, isOn: true, handle: "kit") == "Unmute @kit")
        #expect(ProfileModeration.title(for: .block, isOn: false, handle: "kit") == "Block @kit")
        #expect(ProfileModeration.title(for: .block, isOn: true, handle: "kit") == "Unblock @kit")
    }

    @Test("A profile load sets the state; an unknown value leaves it")
    func updateFromProfile() {
        let model = ProfileModeration()
        model.update(muting: true, blocking: nil)
        #expect(model.muting)
        #expect(!model.blocking)
        model.update(muting: nil, blocking: true)
        #expect(model.muting)
        #expect(model.blocking)
    }

    @Test("The flip shows at once and keeps what the server confirms")
    func optimisticSuccess() async {
        let model = ProfileModeration()
        var seenDuringRequest: Bool?
        let outcome = await model.toggle(.mute) { target in
            seenDuringRequest = model.muting
            #expect(model.isPending(.mute))
            return target
        }
        #expect(seenDuringRequest == true)
        #expect(model.muting)
        #expect(!model.isPending(.mute))
        if case .success(true)? = outcome {} else { Issue.record("expected success, got \(String(describing: outcome))") }
    }

    @Test("A refused request rolls the flip back")
    func rollbackOnFailure() async {
        let model = ProfileModeration()
        model.update(muting: nil, blocking: true)
        let outcome = await model.toggle(.block) { _ in
            #expect(!model.blocking)
            throw Refused()
        }
        #expect(model.blocking)
        #expect(!model.isPending(.block))
        if case .failure? = outcome {} else { Issue.record("expected failure") }
    }

    @Test("The server's answer wins over the optimistic value")
    func serverAnswerWins() async {
        let model = ProfileModeration()
        _ = await model.toggle(.mute) { _ in false }
        #expect(!model.muting)
    }

    @Test("A second request for the same kind waits its turn; a profile load can't undo a pending flip")
    func oneRequestPerKind() async {
        let model = ProfileModeration()
        var nestedRefused = false
        _ = await model.toggle(.mute) { target in
            nestedRefused = await model.toggle(.mute) { _ in true } == nil
            model.update(muting: false, blocking: nil)
            #expect(model.muting)
            return target
        }
        #expect(nestedRefused)
        #expect(model.muting)
    }
}

@MainActor
@Suite("Profile text")
struct ProfileTextTests {
    private let font = UIFont.systemFont(ofSize: 17)

    @Test("Websites show as host and path, without scheme, www or a trailing slash")
    func websiteLabels() {
        #expect(ProfileText.websiteLabel("https://www.example.com/") == "example.com")
        #expect(ProfileText.websiteLabel("https://example.com/blog/") == "example.com/blog")
        #expect(ProfileText.websiteLabel("http://sub.example.org/a/b") == "sub.example.org/a/b")
        #expect(ProfileText.websiteLabel("example.com/x") == "example.com/x")
        let long = ProfileText.websiteLabel("https://example.com/" + String(repeating: "a", count: 60))
        #expect(long.count == 40)
        #expect(long.hasSuffix("…"))
    }

    @Test("Website addresses open over http(s) only")
    func websiteURLs() {
        #expect(ProfileText.websiteURL("example.com")?.absoluteString == "https://example.com")
        #expect(ProfileText.websiteURL("http://example.com/x")?.absoluteString == "http://example.com/x")
        #expect(ProfileText.websiteURL("javascript:alert(1)") == nil)
        #expect(ProfileText.websiteURL("  ") == nil)
    }

    @Test("A bio's mentions open profiles and its links show short but open in full")
    func bioLinks() {
        let bio = ProfileText.bio("Drawing for @anyavoss's book. More at https://www.example.com/work/ #art", font: font)
        #expect(bio.string == "Drawing for @anyavoss's book. More at example.com/work #art")
        let links = ProfileText.links(in: bio)
        #expect(links.map(\.name) == ["@anyavoss", "example.com/work", "#art"])
        #expect(links.map(\.url.absoluteString) == [
            "unrager://profile/anyavoss", "https://www.example.com/work/", "unrager://hashtag/art",
        ])
    }

    @Test("A bio keeps every line")
    func bioKeepsLines() {
        let bio = ProfileText.bio("first\nsecond\nthird", font: font)
        #expect(bio.string == "first\nsecond\nthird")
    }

    @Test("Join dates name the month in the reader's language")
    func joinedDates() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2019-03-15T12:00:00Z"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(ProfileText.joined(date, locale: Locale(identifier: "en_US"), timeZone: utc) == "Joined March 2019")
        let german = ProfileText.joined(date, locale: Locale(identifier: "de_DE"), timeZone: utc)
        #expect(german.contains("März"))
        #expect(german.contains("2019"))
        let finnish = ProfileText.joined(date, locale: Locale(identifier: "fi_FI"), timeZone: utc)
        #expect(finnish.contains("maaliskuu"))
    }

    @Test("The meta line links the website and is absent when there's nothing to say")
    func metaLine() throws {
        #expect(ProfileText.meta(location: " ", website: nil, joinedAt: nil, font: font) == nil)
        let line = try #require(ProfileText.meta(location: "Berlin", website: "https://example.com/notes",
                                                 joinedAt: nil, font: font))
        #expect(line.string.contains("Berlin"))
        #expect(line.string.contains("example.com/notes"))
        #expect(ProfileText.links(in: line).map(\.url.absoluteString) == ["https://example.com/notes"])
        #expect(ProfileText.metaAccessibilityLabel(location: "Berlin", website: "https://example.com/notes", joinedAt: nil)
            == "Location: Berlin. Website: example.com/notes")
    }
}
