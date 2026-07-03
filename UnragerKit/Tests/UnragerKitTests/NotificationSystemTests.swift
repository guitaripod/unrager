import Foundation
import Testing
@testable import UnragerKit

@Suite("Notification model decoding (grouping + message fallback)")
struct NotificationDecodingTests {
    private func decode(_ json: String) throws -> XNotification {
        try UnragerJSON.decode(XNotification.self, from: Data(json.utf8))
    }

    @Test("others_count and message decode when present")
    func extendedFieldsPresent() throws {
        let json = """
        {"id":"g1","type":"Like","actors":[{"handle":"a","name":"A","rest_id":"9","verified":false,"avatar_url":null}],
         "others_count":47,"message":"A and 47 others liked your post",
         "target_tweet_id":"1","timestamp":"2026-06-19T12:30:00Z"}
        """
        let notif = try decode(json)
        #expect(notif.othersCount == 47)
        #expect(notif.message == "A and 47 others liked your post")
    }

    @Test("others_count and message are tolerated absent (older servers)")
    func extendedFieldsAbsent() throws {
        let json = """
        {"id":"n1","type":"reply","actors":[],"timestamp":"2026-06-19T12:30:00Z"}
        """
        let notif = try decode(json)
        #expect(notif.othersCount == nil)
        #expect(notif.message == nil)
        #expect(notif.actors.isEmpty)
    }
}

@Suite("Notification seen marker codec")
struct NotificationSeenMarkerTests {
    @Test("Round-trips a timestamp through the wire string")
    func roundTrip() {
        let date = Date(timeIntervalSince1970: 1_782_549_081.371)
        let marker = NotificationSeenMarker(timestamp: date)
        let decoded = try? #require(marker.timestamp)
        #expect(abs((decoded?.timeIntervalSince1970 ?? 0) - date.timeIntervalSince1970) < 0.01)
    }

    @Test("Parses non-fractional ISO 8601 from other clients")
    func plainISOParses() {
        let marker = NotificationSeenMarker(marker: "2026-07-03T13:31:15Z")
        #expect(marker.timestamp != nil)
    }

    @Test("Unknown formats and nil markers degrade to nil, not a crash")
    func garbageDegrades() {
        #expect(NotificationSeenMarker(marker: "cursor-opaque-123").timestamp == nil)
        #expect(NotificationSeenMarker(marker: nil).timestamp == nil)
    }
}

/// Serialized recursively: everything below mutates the shared
/// `NotificationPrefs` UserDefaults keys, so prefs and poller tests must not
/// interleave with each other.
@Suite("Notification state (shared UserDefaults)", .serialized)
enum NotificationStateTests {}

extension NotificationStateTests {
@Suite("NotificationPrefs")
struct NotificationPrefsTests {
    private static let keys = [
        "unrager.notifications.bannersEnabled",
        "unrager.notifications.lastSeenID",
        "unrager.notifications.lastSeenTimestamp",
        "unrager.notifications.bannerSound",
        "unrager.notifications.quietHours.enabled",
        "unrager.notifications.quietHours.startMinute",
        "unrager.notifications.quietHours.endMinute",
        "unrager.notifications.deliveredBannerIDs",
    ] + NotificationKind.allCases.map { "unrager.notifications.kind.\($0.rawValue)" }

    private func withCleanPrefs(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try body()
    }

    @Test("High-value kinds alert by default; likes and reposts don't")
    func alertDefaults() {
        withCleanPrefs {
            #expect(NotificationPrefs.bannerEnabled(for: .reply))
            #expect(NotificationPrefs.bannerEnabled(for: .mention))
            #expect(NotificationPrefs.bannerEnabled(for: .quote))
            #expect(NotificationPrefs.bannerEnabled(for: .follow))
            #expect(!NotificationPrefs.bannerEnabled(for: .like))
            #expect(!NotificationPrefs.bannerEnabled(for: .repost))
        }
    }

    @Test("Toasts honor per-kind mutes and never fire for unmapped junk types")
    func toastGating() {
        withCleanPrefs {
            #expect(NotificationPrefs.shouldToast(rawType: "reply"))
            #expect(!NotificationPrefs.shouldToast(rawType: "like"))
            NotificationPrefs.setBannerEnabled(true, for: .like)
            #expect(NotificationPrefs.shouldToast(rawType: "like"))
            NotificationPrefs.setBannerEnabled(false, for: .reply)
            #expect(!NotificationPrefs.shouldToast(rawType: "reply"))
            #expect(!NotificationPrefs.shouldToast(rawType: "recommendation"))
            #expect(!NotificationPrefs.shouldToast(rawType: "trending"))
            #expect(!NotificationPrefs.shouldToast(rawType: "poll"))
        }
    }

    @Test("Quiet hours match inside the window, including a midnight wrap")
    func quietHours() {
        withCleanPrefs {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            func date(hour: Int, minute: Int) -> Date {
                calendar.date(from: DateComponents(year: 2026, month: 7, day: 3, hour: hour, minute: minute))!
            }
            #expect(!NotificationPrefs.isQuietHours(at: date(hour: 23, minute: 0), calendar: calendar))
            NotificationPrefs.quietHoursEnabled = true
            NotificationPrefs.quietHoursStartMinute = 22 * 60
            NotificationPrefs.quietHoursEndMinute = 8 * 60
            #expect(NotificationPrefs.isQuietHours(at: date(hour: 23, minute: 0), calendar: calendar))
            #expect(NotificationPrefs.isQuietHours(at: date(hour: 3, minute: 30), calendar: calendar))
            #expect(!NotificationPrefs.isQuietHours(at: date(hour: 12, minute: 0), calendar: calendar))
            NotificationPrefs.quietHoursStartMinute = 9 * 60
            NotificationPrefs.quietHoursEndMinute = 17 * 60
            #expect(NotificationPrefs.isQuietHours(at: date(hour: 12, minute: 0), calendar: calendar))
            #expect(!NotificationPrefs.isQuietHours(at: date(hour: 20, minute: 0), calendar: calendar))
            NotificationPrefs.quietHoursEndMinute = 9 * 60
            #expect(!NotificationPrefs.isQuietHours(at: date(hour: 9, minute: 0), calendar: calendar))
        }
    }

    @Test("The seen marker is monotonic and adoptable from a remote timestamp")
    func markerMonotonic() {
        withCleanPrefs {
            let older = Date(timeIntervalSince1970: 1_000)
            let newer = Date(timeIntervalSince1970: 2_000)
            #expect(NotificationPrefs.markSeen(timestamp: newer, id: "n2"))
            #expect(!NotificationPrefs.markSeen(timestamp: older, id: "n1"))
            #expect(NotificationPrefs.lastSeenTimestamp == newer)
        }
    }

    @Test("Delivered-banner ids dedupe and stay capped")
    func deliveredBannerCap() {
        withCleanPrefs {
            NotificationPrefs.recordDeliveredBanners(ids: ["a", "b"])
            NotificationPrefs.recordDeliveredBanners(ids: ["b", "c"])
            #expect(NotificationPrefs.hasDeliveredBanner(id: "a"))
            #expect(NotificationPrefs.hasDeliveredBanner(id: "c"))
            #expect(!NotificationPrefs.hasDeliveredBanner(id: "z"))
            NotificationPrefs.recordDeliveredBanners(ids: (0..<400).map { "bulk-\($0)" })
            #expect(!NotificationPrefs.hasDeliveredBanner(id: "a"))
            #expect(NotificationPrefs.hasDeliveredBanner(id: "bulk-399"))
        }
    }
}

@Suite("NotificationPoller")
struct NotificationPollerTests {
    private actor StubTransport: HTTPTransport {
        var notificationBodies: [String]
        var seenResponses: [(Int, String)]

        init(notificationBodies: [String], seenResponses: [(Int, String)] = []) {
            self.notificationBodies = notificationBodies
            self.seenResponses = seenResponses
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            if request.url.path.contains("notifications/seen") {
                let (status, body) = seenResponses.isEmpty
                    ? (404, #"{"error":"no route","kind":"not_found"}"#)
                    : seenResponses.removeFirst()
                return HTTPResponse(status: status, headers: [:], body: Data(body.utf8))
            }
            let body = notificationBodies.count > 1 ? notificationBodies.removeFirst() : notificationBodies[0]
            return HTTPResponse(status: 200, headers: [:], body: Data(body.utf8))
        }

        func stream(_ request: HTTPRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
            (200, AsyncThrowingStream { $0.finish() })
        }
    }

    private func page(_ items: [(id: String, timestamp: String)]) -> String {
        let rows = items.map {
            #"{"id":"\#($0.id)","type":"reply","actors":[],"timestamp":"\#($0.timestamp)"}"#
        }.joined(separator: ",")
        return #"{"notifications":[\#(rows)],"cursor":null}"#
    }

    @MainActor
    private func withCleanMarker(_ body: @MainActor () async -> Void) async {
        let defaults = UserDefaults.standard
        let keys = ["unrager.notifications.lastSeenID", "unrager.notifications.lastSeenTimestamp"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        await body()
    }

    @MainActor
    @Test("Fresh install: first poll baselines without alerting; later arrivals count unread and alert")
    func freshInstallBaseline() async {
        await withCleanMarker {
            let transport = StubTransport(notificationBodies: [
                page([("n1", "2026-07-01T10:00:00Z")]),
                page([("n2", "2026-07-01T11:00:00Z"), ("n1", "2026-07-01T10:00:00Z")]),
            ])
            let api = APIClient(transport: transport, baseURL: { URL(string: "http://test:7777")! })
            let poller = NotificationPoller(api: api)
            var unreadCounts: [Int] = []
            var alerted: [[XNotification]] = []
            poller.onUnreadCount = { unreadCounts.append($0) }
            poller.onNewNotifications = { alerted.append($0) }

            #expect(await poller.poll())
            #expect(unreadCounts == [0])
            #expect(alerted.isEmpty)
            #expect(NotificationPrefs.lastSeenTimestamp != nil)

            #expect(await poller.poll())
            #expect(unreadCounts == [0, 1])
            #expect(alerted.count == 1)
            #expect(alerted.first?.map(\.id) == ["n2"])
            #expect(poller.latestFetched?.id == "n2")
            #expect(poller.lastPage.count == 2)
        }
    }

    @MainActor
    @Test("A 404 seen endpoint is tolerated: polling and local tracking keep working")
    func missingSeenEndpointTolerated() async {
        await withCleanMarker {
            let transport = StubTransport(notificationBodies: [page([("n1", "2026-07-01T10:00:00Z")])])
            let api = APIClient(transport: transport, baseURL: { URL(string: "http://test:7777")! })
            let seen = NotificationSeenAPI(transport: transport, baseURL: { URL(string: "http://test:7777")! })
            let poller = NotificationPoller(api: api, seenAPI: seen)
            #expect(await poller.poll())
            #expect(NotificationPrefs.lastSeenTimestamp != nil)
        }
    }

    @MainActor
    @Test("A newer server marker is adopted; an older one is ignored")
    func serverMarkerAdoption() async {
        await withCleanMarker {
            NotificationPrefs.markSeen(timestamp: Date(timeIntervalSince1970: 1_000))
            let newer = NotificationSeenMarker(timestamp: Date(timeIntervalSince1970: 5_000))
            let transport = StubTransport(
                notificationBodies: [page([("n1", "1970-01-01T00:00:30Z")])],
                seenResponses: [(200, #"{"marker":"\#(newer.marker!)"}"#)])
            let api = APIClient(transport: transport, baseURL: { URL(string: "http://test:7777")! })
            let seen = NotificationSeenAPI(transport: transport, baseURL: { URL(string: "http://test:7777")! })
            let poller = NotificationPoller(api: api, seenAPI: seen)
            #expect(await poller.poll())
            #expect(NotificationPrefs.lastSeenTimestamp == Date(timeIntervalSince1970: 5_000))
        }
    }
}
}
