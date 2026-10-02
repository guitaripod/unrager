import Foundation
import Testing
import UnragerKit
@testable import Unrager

@MainActor
@Suite("Notifications list and settings")
struct NotificationsLogicTests {
    private func notif(_ id: String, actors: [String], others: Int = 0, at seconds: Int) throws -> XNotification {
        let people = actors.enumerated().map { index, name in
            #"{"handle":"\#(name)","name":"\#(name)","rest_id":"\#(index + 1)","verified":false}"#
        }
        let json = """
        {"id":"\(id)","type":"like","actors":[\(people.joined(separator: ","))],"others_count":\(others),
         "target_tweet_id":"9","timestamp":"\(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds))))"}
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

    @Test("The people list says how many X left out")
    func othersNote() {
        #expect(NotificationActorsViewController.othersNote(0) == nil)
        #expect(NotificationActorsViewController.othersNote(1) == "And 1 other X doesn't list here.")
        #expect(NotificationActorsViewController.othersNote(47) == "And 47 others X doesn't list here.")
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
