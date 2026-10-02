import Foundation

public enum Format {
    /// Compact engagement count, e.g. 1234 → "1.2K", 2_500_000 → "2.5M". The
    /// thresholds sit just below each power, so a value that would round up to
    /// "1000K" or "1000M" rolls over to "1M" or "1B" instead.
    public static func count(_ value: Int) -> String {
        let n = Double(value)
        switch abs(value) {
        case 999_500_000...:
            return trim(n / 1_000_000_000) + "B"
        case 999_500...:
            return trim(n / 1_000_000) + "M"
        case 10_000...:
            return trim(n / 1_000, maxFractionForLarge: true) + "K"
        case 1_000...:
            return trim(n / 1_000) + "K"
        default:
            return String(value)
        }
    }

    private static func trim(_ value: Double, maxFractionForLarge: Bool = false) -> String {
        if maxFractionForLarge || value >= 100 {
            return String(Int(value.rounded()))
        }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    /// Short relative timestamp: "12s", "5m", "3h", "2d", then "Apr 5" /
    /// "Apr 5, 2024" for older dates.
    public static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        relativeTime(date, now: now, locale: .autoupdatingCurrent)
    }

    static func relativeTime(_ date: Date, now: Date, locale: Locale) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "\(max(0, Int(seconds)))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400))d" }

        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return date.formatted((sameYear ? shortDate : longDate).locale(locale))
    }

    /// Absolute timestamp for detail views in the reader's own conventions
    /// (12- or 24-hour clock, day-month order), e.g. "3:21 PM · Jun 19, 2026".
    public static func absoluteTime(_ date: Date) -> String {
        absoluteTime(date, locale: .autoupdatingCurrent)
    }

    static func absoluteTime(_ date: Date, locale: Locale) -> String {
        "\(date.formatted(clock.locale(locale))) · \(date.formatted(longDate.locale(locale)))"
    }

    /// Value-type styles on the auto-updating locale and time zone, so a
    /// change to the language, region, 12/24-hour setting or time zone shows
    /// up at once rather than after a relaunch; Foundation caches the
    /// underlying formatters, so formatting a row stays cheap.
    private static let shortDate = Date.FormatStyle.dateTime.month(.abbreviated).day()
    private static let longDate = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
    private static let clock = Date.FormatStyle.dateTime.hour().minute()
}
