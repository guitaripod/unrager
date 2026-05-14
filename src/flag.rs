//! Converts the country / region string returned by X's `AboutAccountQuery`
//! (e.g. `"United States"`, `"Indonesia"`, `"Europe"`) into a flag emoji.
//!
//! ISO 3166-1 country lookup is delegated to the `celes` crate so we don't
//! ship our own gazetteer. The only manual override is for X's `"Europe"`
//! region value, which is not an ISO country but does map to a stable
//! Unicode regional indicator pair (`EU` -> the EU flag).
//!
//! The flag emoji itself is two regional-indicator codepoints derived from
//! the alpha-2 code; terminals that lack flag glyphs will simply render the
//! letter pair, which is still informative.

use celes::Country;
use std::str::FromStr;

pub fn alpha2_for(raw: &str) -> Option<&'static str> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.eq_ignore_ascii_case("Europe") {
        return Some("EU");
    }
    let compact: String = trimmed.chars().filter(|c| !c.is_whitespace()).collect();
    Country::from_str(&compact).ok().map(|c| c.alpha2)
}

pub fn emoji_for(raw: &str) -> Option<String> {
    let code = alpha2_for(raw)?;
    Some(alpha2_to_emoji(code))
}

fn alpha2_to_emoji(code: &str) -> String {
    let mut out = String::with_capacity(8);
    for b in code.as_bytes() {
        let upper = b.to_ascii_uppercase();
        if !upper.is_ascii_uppercase() {
            return String::new();
        }
        let cp = 0x1F1E6u32 + (upper - b'A') as u32;
        out.push(char::from_u32(cp).expect("regional indicator codepoint"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alpha2_known_country_names_resolve() {
        assert_eq!(alpha2_for("Indonesia"), Some("ID"));
        assert_eq!(alpha2_for("Japan"), Some("JP"));
        assert_eq!(alpha2_for("Canada"), Some("CA"));
    }

    #[test]
    fn alpha2_multiword_country_resolves() {
        assert_eq!(alpha2_for("United States"), Some("US"));
        assert_eq!(alpha2_for("New Zealand"), Some("NZ"));
        assert_eq!(alpha2_for("South Africa"), Some("ZA"));
    }

    #[test]
    fn alpha2_trims_whitespace_and_is_case_insensitive() {
        assert_eq!(alpha2_for("  united states  "), Some("US"));
        assert_eq!(alpha2_for("japan"), Some("JP"));
    }

    #[test]
    fn alpha2_handles_eu_region() {
        assert_eq!(alpha2_for("Europe"), Some("EU"));
    }

    #[test]
    fn alpha2_unknown_returns_none() {
        assert_eq!(alpha2_for("Mordor"), None);
        assert_eq!(alpha2_for(""), None);
        assert_eq!(alpha2_for("    "), None);
    }

    #[test]
    fn emoji_two_codepoints() {
        let s = emoji_for("Japan").unwrap();
        assert_eq!(s.chars().count(), 2);
    }

    #[test]
    fn emoji_unknown_is_none() {
        assert!(emoji_for("Mordor").is_none());
    }

    #[test]
    fn alpha2_to_emoji_us_codepoints() {
        let chars: Vec<char> = alpha2_to_emoji("US").chars().collect();
        assert_eq!(chars.len(), 2);
        assert_eq!(chars[0] as u32, 0x1F1FA);
        assert_eq!(chars[1] as u32, 0x1F1F8);
    }
}
