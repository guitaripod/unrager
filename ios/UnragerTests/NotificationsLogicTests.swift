import Foundation
import Testing
import UnragerKit
@testable import Unrager

@MainActor
@Suite("Notifications list and settings")
struct NotificationsLogicTests {
    private func notif(_ id: String, type: String = "like", actors: [String], others: Int = 0, at seconds: Int,
                       tweet: String? = "9") throws -> XNotification {
        let people = actors.enumerated().map { index, name in
            #"{"handle":"\#(name)","name":"\#(name)","rest_id":"\#(index + 1)","verified":false}"#
        }
        let tweetField = tweet.map { "\"target_tweet_id\":\"\($0)\"," } ?? ""
        let json = """
        {"id":"\(id)","type":"\(type)","actors":[\(people.joined(separator: ","))],"others_count":\(others),
         \(tweetField)"timestamp":"\(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds))))"}
        """
        return try UnragerJSON.decode(XNotification.self, from: Data(json.utf8))
    }

    @Test("A grown group replaces its row and moves to the top; an unchanged one changes nothing")
    func mergeGrownGroup() throws {
        let old = try notif("a", actors: ["alice"], at: 100)
        let other = try notif("b", actors: ["bob"], at: 200)
        let items = ["a": old, "b": other]
        let grown = try notif("a", actors: ["alice", "bob"], others: 3, at: 300)
        let merged = NotificationsViewController.merge([grown], into: ["b", "a"], items: items)
        #expect(merged.order == ["a", "b"])
        #expect(merged.grown == ["a"])
        #expect(merged.incoming == [grown])

        let unchanged = NotificationsViewController.merge([other], into: ["b", "a"], items: items)
        #expect(unchanged.incoming.isEmpty && unchanged.order == ["b", "a"])

        let fresh = try notif("c", actors: ["cy"], at: 400)
        let both = NotificationsViewController.merge([fresh, grown], into: ["b", "a"], items: items)
        #expect(both.order == ["c", "a", "b"])
        #expect(both.grown == ["a"])
    }

    @Test("Names read the way a sentence does")
    func whoText() throws {
        #expect(NotificationPresentation.whoText(for: try notif("a", actors: [], at: 1)) == nil)
        #expect(NotificationPresentation.whoText(for: try notif("a", actors: ["ann"], at: 1)) == "ann")
        #expect(NotificationPresentation.whoText(for: try notif("a", actors: ["ann", "bo"], at: 1)) == "ann and bo")
        #expect(NotificationPresentation.whoText(for: try notif("a", actors: ["ann", "bo", "cy"], at: 1)) == "ann, bo and 1 other")
        #expect(NotificationPresentation.whoText(for: try notif("a", actors: ["ann", "bo"], others: 41, at: 1))
                == "ann, bo and 41 others")
        #expect(NotificationPresentation.whoText(for: try notif("a", actors: ["ann"], others: 1, at: 1)) == "ann and 1 other")
    }

    @Test("The raw type decides the style, whatever its case or underscores")
    func typeParsing() {
        #expect(NotificationType(raw: "Like") == .like)
        #expect(NotificationType(raw: "FAVORITE") == .like)
        #expect(NotificationType(raw: "retweet") == .repost)
        #expect(NotificationType(raw: "community_note") == .communityNote)
        #expect(NotificationType(raw: "poll_ended") == .other("poll ended"))
        #expect(NotificationType.reply.isConversation && NotificationType.quote.isConversation)
        #expect(NotificationType.like.isEngagement && !NotificationType.follow.isEngagement)
    }

    @Test("Chips narrow the list; Mentions takes replies, mentions and quotes")
    func categories() throws {
        let like = try notif("l", type: "Like", actors: ["a"], at: 1)
        let reply = try notif("r", type: "Reply", actors: ["a"], at: 1)
        let quote = try notif("q", type: "Quote", actors: ["a"], at: 1)
        let follow = try notif("f", type: "Follow", actors: ["a"], at: 1, tweet: nil)
        let repost = try notif("p", type: "Retweet", actors: ["a"], at: 1)
        let all = [like, reply, quote, follow, repost]
        #expect(all.filter(NotificationCategory.all.includes).count == 5)
        #expect(all.filter(NotificationCategory.mentions.includes).map(\.id) == ["r", "q"])
        #expect(all.filter(NotificationCategory.likes.includes).map(\.id) == ["l"])
        #expect(all.filter(NotificationCategory.reposts.includes).map(\.id) == ["p"])
        #expect(all.filter(NotificationCategory.follows.includes).map(\.id) == ["f"])
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("Unread leads; the rest fall under their day, in order, with empty days left out")
    func sections() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let rows = [
            try notif("new", actors: ["a"], at: 999_000),
            try notif("today", actors: ["a"], at: 990_000),
            try notif("today2", actors: ["a"], at: 960_000),
            try notif("yesterday", actors: ["a"], at: 900_000),
            try notif("week", actors: ["a"], at: 600_000),
            try notif("earlier", actors: ["a"], at: 100_000),
        ]
        let items = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let result = NotificationPresentation.sections(
            order: rows.map(\.id), items: items, isUnread: { $0.id == "new" }, now: now, calendar: utc)
        #expect(result.map(\.section) == [.new, .today, .yesterday, .thisWeek, .earlier])
        #expect(result[1].ids == ["today", "today2"])

        let quiet = NotificationPresentation.sections(
            order: ["today", "week"], items: items, isUnread: { _ in false }, now: now, calendar: utc)
        #expect(quiet.map(\.section) == [.today, .thisWeek])
    }

    @Test("A time just after midnight is today, just before it is yesterday")
    func dayBoundary() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let midnight = Date(timeIntervalSince1970: 950_400)
        #expect(NotificationSection.bucket(for: midnight, now: now, calendar: utc) == .today)
        #expect(NotificationSection.bucket(for: midnight.addingTimeInterval(-1), now: now, calendar: utc) == .yesterday)
        #expect(NotificationSection.bucket(for: now.addingTimeInterval(3_600), now: now, calendar: utc) == .today)
    }

    @Test("The digest names the three biggest kinds, conversation first, people counted in full")
    func digest() throws {
        let like = try notif("l", type: "Like", actors: ["a", "b", "c"], others: 41, at: 1)
        let reply = try notif("r", type: "Reply", actors: ["a"], at: 1)
        let follow = try notif("f", type: "Follow", actors: ["a", "b"], others: 6, at: 1, tweet: nil)
        #expect(NotificationPresentation.digest(of: []) == nil)
        #expect(NotificationPresentation.digest(of: [like, reply, follow]) == "1 reply · 8 new followers · 44 likes")
        let repost = try notif("p", type: "Retweet", actors: ["a"], at: 1)
        #expect(NotificationPresentation.digest(of: [like, reply, follow, repost]) == "1 reply · 8 new followers · 1 repost")
        #expect(NotificationPresentation.digest(of: [try notif("x", type: "Follow", actors: ["a"], at: 1, tweet: nil)])
                == "1 new follower")
    }

    @Test("A row opens its post, else its people, else its person")
    func destinations() throws {
        #expect(NotificationPresentation.destination(of: try notif("a", actors: ["x"], at: 1)) == .post("9"))
        #expect(NotificationPresentation.destination(of: try notif("a", type: "Follow", actors: ["x", "y"], at: 1, tweet: nil)) == .people)
        #expect(NotificationPresentation.destination(of: try notif("a", type: "Follow", actors: ["x"], at: 1, tweet: nil))
                == .profile("x"))
        #expect(NotificationPresentation.destination(of: try notif("a", type: "Poll", actors: [], at: 1, tweet: nil)) == nil)
    }

    @Test("Banner copy names the people, falls back to X's message, and never says Someone Poll")
    func bannerCopy() throws {
        let like = try notif("l", type: "Like", actors: ["ann", "bo"], others: 3, at: 1)
        #expect(NotificationPresentation.bannerCopy(for: like).title == "ann, bo and 3 others liked your post")
        let message = try UnragerJSON.decode(XNotification.self, from: Data(
            #"{"id":"m","type":"poll","actors":[],"message":"Your poll has ended","timestamp":"2026-01-01T00:00:00Z"}"#.utf8))
        #expect(NotificationPresentation.bannerCopy(for: message).title == "Your poll has ended")
    }

    @Test("The people list says how many X left out")
    func othersNote() {
        #expect(NotificationActorsViewController.othersNote(0) == nil)
        #expect(NotificationActorsViewController.othersNote(1) == "And 1 other X doesn't list here.")
        #expect(NotificationActorsViewController.othersNote(47) == "And 47 others X doesn't list here.")
    }

    @Test("Diagnostics say when the last check ran and why it failed")
    func diagnosticsText() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(NotificationSettingsViewController.checkText(at: nil, error: nil, now: now) == "Not yet")
        #expect(NotificationSettingsViewController.checkText(at: now, error: nil, now: now) == "OK, just now")
        #expect(NotificationSettingsViewController.checkText(
            at: now.addingTimeInterval(-120), error: nil, now: now) == "OK, 2m ago")
        #expect(NotificationSettingsViewController.checkText(
            at: now.addingTimeInterval(-30), error: "Server unreachable", now: now)
            == "Failed 30s ago: Server unreachable")
        #expect(NotificationSettingsViewController.permissionText(.denied) == "Off in iOS Settings")
        #expect(NotificationSettingsViewController.permissionText(nil) == "Checking…")
        #expect(NotificationSettingsViewController.seenSyncText(.unsupported) == "Off: this server doesn't sync it")
    }

    @Test("The banners footer explains a refusal in iOS Settings and a window that never applies")
    func bannersFooter() {
        let plain = NotificationSettingsViewController.bannersFooter(
            deniedBySystem: false, bannersOn: true, quietHoursOn: true, quietStart: 22 * 60, quietEnd: 8 * 60)
        #expect(plain.hasPrefix("While Unrager is open"))
        let denied = NotificationSettingsViewController.bannersFooter(
            deniedBySystem: true, bannersOn: true, quietHoursOn: false, quietStart: 0, quietEnd: 0)
        #expect(denied.hasPrefix("Off in iOS Settings"))
        let same = NotificationSettingsViewController.bannersFooter(
            deniedBySystem: false, bannersOn: true, quietHoursOn: true, quietStart: 600, quietEnd: 600)
        #expect(same.hasPrefix("Start and end are the same"))
        let off = NotificationSettingsViewController.bannersFooter(
            deniedBySystem: true, bannersOn: false, quietHoursOn: true, quietStart: 600, quietEnd: 600)
        #expect(off.hasPrefix("While Unrager is open"))
    }
}
