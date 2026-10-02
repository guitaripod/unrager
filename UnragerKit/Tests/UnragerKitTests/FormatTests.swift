import Foundation
import Testing
@testable import UnragerKit

@Suite("Format")
struct FormatTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Relative times step from seconds to days")
    func relativeSteps() {
        #expect(Format.relativeTime(now.addingTimeInterval(-12), now: now) == "12s")
        #expect(Format.relativeTime(now.addingTimeInterval(-300), now: now) == "5m")
        #expect(Format.relativeTime(now.addingTimeInterval(-3 * 3_600), now: now) == "3h")
        #expect(Format.relativeTime(now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
    }

    @Test("A future timestamp from a skewed clock reads as zero seconds, never negative")
    func futureClamps() {
        #expect(Format.relativeTime(now.addingTimeInterval(30), now: now) == "0s")
    }

    @Test("Older dates fall back to a date, with the year only when it differs")
    func olderDates() {
        let lastWeek = Format.relativeTime(now.addingTimeInterval(-10 * 86_400), now: now)
        #expect(!lastWeek.contains("d"))
        let yearsAgo = Format.relativeTime(now.addingTimeInterval(-800 * 86_400), now: now)
        #expect(yearsAgo.contains("2024") || yearsAgo.contains("2025"))
    }

    @Test("The absolute timestamp joins the clock and the full date")
    func absolute() {
        let text = Format.absoluteTime(now)
        #expect(text.contains(" · "))
        #expect(text.contains("2026"))
    }

    @Test("Timestamps follow the locale they're formatted in, not the one first used")
    func followsLocale() {
        let us = Format.absoluteTime(now, locale: Locale(identifier: "en_US"))
        let de = Format.absoluteTime(now, locale: Locale(identifier: "de_DE"))
        #expect(us.contains("AM") || us.contains("PM"))
        #expect(!de.contains("AM") && !de.contains("PM"))
        let older = now.addingTimeInterval(-10 * 86_400)
        #expect(Format.relativeTime(older, now: now, locale: Locale(identifier: "en_US"))
            != Format.relativeTime(older, now: now, locale: Locale(identifier: "fi_FI")))
    }

    @Test("Counts compact and roll over cleanly")
    func counts() {
        #expect(Format.count(999) == "999")
        #expect(Format.count(1_234) == "1.2K")
        #expect(Format.count(999_600) == "1M")
        #expect(Format.count(2_500_000) == "2.5M")
    }
}
