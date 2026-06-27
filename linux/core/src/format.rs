//! Display formatting, ported byte-for-byte from `UnragerKit/Support/Format.swift`
//! so the GTK client renders counts and timestamps identically to the Apple apps.

use chrono::{DateTime, Datelike, Local, TimeZone, Utc};

/// Compact engagement count, e.g. `1234 → "1.2K"`, `2_500_000 → "2.5M"`.
pub fn count(value: i64) -> String {
    let n = value as f64;
    // Thresholds sit just below each power so a value that would round up to
    // "1000K" / "1000M" rolls over to "1M" / "1B" instead.
    match value.unsigned_abs() {
        999_500_000.. => trim(n / 1_000_000_000.0, false) + "B",
        999_500.. => trim(n / 1_000_000.0, false) + "M",
        10_000.. => trim(n / 1_000.0, true) + "K",
        1_000.. => trim(n / 1_000.0, false) + "K",
        _ => value.to_string(),
    }
}

fn trim(value: f64, max_fraction_for_large: bool) -> String {
    if max_fraction_for_large || value >= 100.0 {
        return (value.round() as i64).to_string();
    }
    let rounded = (value * 10.0).round() / 10.0;
    if rounded == rounded.round() {
        (rounded as i64).to_string()
    } else {
        format!("{rounded:.1}")
    }
}

/// Short relative timestamp: `"12s"`, `"5m"`, `"3h"`, `"2d"`, then `"Apr 5"` /
/// `"Apr 5, 2024"` for older dates. Dates older than a week render in the local
/// timezone, matching the Apple apps' `Calendar.current`.
pub fn relative_time(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    relative_time_in(date, now, &Local)
}

/// Absolute timestamp for detail views, e.g. `"3:21 PM · Jun 19, 2026"`, in the
/// local timezone.
pub fn absolute_time(date: DateTime<Utc>) -> String {
    absolute_time_in(date, &Local)
}

/// "updated Nm ago" for a materialized-feed age in seconds, or `None` when the
/// buffer has never been ingested (`age_secs < 0`). Used for the freshness
/// indicator on Home feeds.
pub fn freshness_label(age_secs: i64) -> Option<String> {
    if age_secs < 0 {
        return None;
    }
    let unit = if age_secs < 60 {
        format!("{age_secs}s")
    } else if age_secs < 3_600 {
        format!("{}m", age_secs / 60)
    } else if age_secs < 86_400 {
        format!("{}h", age_secs / 3_600)
    } else {
        format!("{}d", age_secs / 86_400)
    };
    Some(format!("updated {unit} ago"))
}

fn relative_time_in<Tz: TimeZone>(date: DateTime<Utc>, now: DateTime<Utc>, tz: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    let seconds = now.signed_duration_since(date).num_seconds();
    if seconds < 60 {
        return format!("{}s", seconds.max(0));
    }
    if seconds < 3_600 {
        return format!("{}m", seconds / 60);
    }
    if seconds < 86_400 {
        return format!("{}h", seconds / 3_600);
    }
    if seconds < 604_800 {
        return format!("{}d", seconds / 86_400);
    }
    let local = date.with_timezone(tz);
    if local.year() == now.with_timezone(tz).year() {
        local.format("%b %-d").to_string()
    } else {
        local.format("%b %-d, %Y").to_string()
    }
}

fn absolute_time_in<Tz: TimeZone>(date: DateTime<Utc>, tz: &Tz) -> String
where
    Tz::Offset: std::fmt::Display,
{
    date.with_timezone(tz)
        .format("%-I:%M %p · %b %-d, %Y")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn compact_counts_match_apple_fixtures() {
        assert_eq!(count(950), "950");
        assert_eq!(count(1234), "1.2K");
        assert_eq!(count(2_500_000), "2.5M");
    }

    #[test]
    fn compact_count_bands() {
        assert_eq!(count(0), "0");
        assert_eq!(count(999), "999");
        assert_eq!(count(1_000), "1K");
        assert_eq!(count(9_999), "10K");
        assert_eq!(count(10_000), "10K");
        assert_eq!(count(12_500), "13K");
        assert_eq!(count(100_000), "100K");
        assert_eq!(count(999_499), "999K");
        assert_eq!(count(999_999), "1M");
        assert_eq!(count(1_000_000), "1M");
        assert_eq!(count(1_500_000), "1.5M");
        assert_eq!(count(1_000_000_000), "1B");
    }

    #[test]
    fn relative_time_sub_week_branches() {
        let now = utc("2026-06-24T00:00:00Z");
        assert_eq!(relative_time(utc("2026-06-23T23:59:30Z"), now), "30s");
        assert_eq!(relative_time(utc("2026-06-23T23:58:30Z"), now), "1m");
        assert_eq!(relative_time(utc("2026-06-23T23:00:00Z"), now), "1h");
        assert_eq!(relative_time(utc("2026-06-22T23:00:00Z"), now), "1d");
        assert_eq!(relative_time(utc("2026-06-21T00:00:00Z"), now), "3d");
    }

    #[test]
    fn relative_time_future_clamps_to_zero() {
        let now = utc("2026-06-24T00:00:00Z");
        assert_eq!(relative_time(utc("2026-06-24T00:00:05Z"), now), "0s");
    }

    #[test]
    fn relative_time_older_dates_use_month_day() {
        let now = utc("2026-06-24T12:00:00Z");
        assert_eq!(
            relative_time_in(utc("2026-06-05T12:00:00Z"), now, &Utc),
            "Jun 5"
        );
        assert_eq!(
            relative_time_in(utc("2024-06-05T12:00:00Z"), now, &Utc),
            "Jun 5, 2024"
        );
    }

    #[test]
    fn absolute_time_format() {
        assert_eq!(
            absolute_time_in(utc("2026-06-19T15:21:00Z"), &Utc),
            "3:21 PM · Jun 19, 2026"
        );
        assert_eq!(
            absolute_time_in(utc("2026-01-02T09:05:00Z"), &Utc),
            "9:05 AM · Jan 2, 2026"
        );
    }

    #[test]
    fn freshness_label_bands() {
        assert_eq!(freshness_label(-1), None);
        assert_eq!(freshness_label(0).as_deref(), Some("updated 0s ago"));
        assert_eq!(freshness_label(45).as_deref(), Some("updated 45s ago"));
        assert_eq!(freshness_label(120).as_deref(), Some("updated 2m ago"));
        assert_eq!(freshness_label(7_200).as_deref(), Some("updated 2h ago"));
        assert_eq!(freshness_label(172_800).as_deref(), Some("updated 2d ago"));
    }
}
