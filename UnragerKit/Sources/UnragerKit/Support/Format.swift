import Foundation

public enum Format {
    /// Compact engagement count, e.g. 1234 → "1.2K", 2_500_000 → "2.5M".
    public static func count(_ value: Int) -> String {
        let n = Double(value)
        // Thresholds sit just below each power so a value that would round up to
        // "1000K" / "1000M" rolls over to "1M" / "1B" instead.
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
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "\(max(0, Int(seconds)))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400))d" }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    /// Absolute timestamp for detail views, e.g. "3:21 PM · Jun 19, 2026".
    public static func absoluteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a · MMM d, yyyy"
        return formatter.string(from: date)
    }
}
