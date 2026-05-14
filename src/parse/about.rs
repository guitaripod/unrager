use crate::error::{Error, Result};
use crate::model::AboutProfile;
use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;

pub fn parse(response: &Value) -> Result<AboutProfile> {
    let result = response
        .pointer("/data/user_result_by_screen_name/result")
        .ok_or_else(|| {
            Error::GraphqlShape(
                "AboutAccountQuery: missing user_result_by_screen_name.result".into(),
            )
        })?;

    let rest_id = result
        .get("rest_id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::GraphqlShape("AboutAccountQuery: missing rest_id".into()))?
        .to_string();

    let handle = result
        .pointer("/core/screen_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let name = result
        .pointer("/core/name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let about = result.get("about_profile");

    let account_based_in = about
        .and_then(|a| a.get("account_based_in"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let location_accurate = about
        .and_then(|a| a.get("location_accurate"))
        .and_then(Value::as_bool);

    let source = about
        .and_then(|a| a.get("source"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let username_changes = about
        .and_then(|a| a.pointer("/username_changes/count"))
        .and_then(value_as_u64);

    let affiliate_username = about
        .and_then(|a| a.get("affiliate_username"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let created_at = result
        .pointer("/core/created_at")
        .and_then(Value::as_str)
        .and_then(parse_twitter_date);

    let is_blue_verified = result
        .get("is_blue_verified")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let verified = result
        .pointer("/verification/verified")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let verified_since = result
        .pointer("/verification_info/reason/verified_since_msec")
        .and_then(value_as_u64)
        .and_then(|ms| Utc.timestamp_millis_opt(ms as i64).single());

    Ok(AboutProfile {
        rest_id,
        handle,
        name,
        account_based_in,
        location_accurate,
        source,
        username_changes,
        affiliate_username,
        created_at,
        is_blue_verified,
        verified,
        verified_since,
    })
}

fn value_as_u64(v: &Value) -> Option<u64> {
    v.as_u64()
        .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
}

fn parse_twitter_date(raw: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_str(raw, "%a %b %d %H:%M:%S %z %Y")
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn full() -> Value {
        json!({
            "data": {
                "user_result_by_screen_name": {
                    "result": {
                        "rest_id": "159337660",
                        "core": {
                            "created_at": "Fri Jun 25 03:08:49 +0000 2010",
                            "name": "Boris Cherny",
                            "screen_name": "bcherny"
                        },
                        "is_blue_verified": true,
                        "verification": { "verified": false },
                        "verification_info": {
                            "reason": { "verified_since_msec": "1754186580549" }
                        },
                        "about_profile": {
                            "account_based_in": "United States",
                            "location_accurate": true,
                            "source": "United States App Store",
                            "username_changes": { "count": "3" },
                            "affiliate_username": "X"
                        }
                    }
                }
            }
        })
    }

    #[test]
    fn parses_full_profile() {
        let p = parse(&full()).unwrap();
        assert_eq!(p.rest_id, "159337660");
        assert_eq!(p.handle, "bcherny");
        assert_eq!(p.name, "Boris Cherny");
        assert_eq!(p.account_based_in.as_deref(), Some("United States"));
        assert_eq!(p.location_accurate, Some(true));
        assert_eq!(p.source.as_deref(), Some("United States App Store"));
        assert_eq!(p.username_changes, Some(3));
        assert_eq!(p.affiliate_username.as_deref(), Some("X"));
        assert!(p.is_blue_verified);
        assert!(!p.verified);
        assert!(p.created_at.is_some());
        assert!(p.verified_since.is_some());
    }

    #[test]
    fn missing_about_profile_is_ok() {
        let mut v = full();
        v["data"]["user_result_by_screen_name"]["result"]
            .as_object_mut()
            .unwrap()
            .remove("about_profile");
        let p = parse(&v).unwrap();
        assert_eq!(p.handle, "bcherny");
        assert!(p.account_based_in.is_none());
        assert!(p.location_accurate.is_none());
        assert!(p.source.is_none());
        assert!(p.username_changes.is_none());
        assert!(p.affiliate_username.is_none());
    }

    #[test]
    fn missing_optional_fields_are_none() {
        let v = json!({
            "data": {
                "user_result_by_screen_name": {
                    "result": {
                        "rest_id": "12",
                        "core": { "screen_name": "jack", "name": "jack" },
                        "about_profile": {
                            "account_based_in": "United States",
                            "source": "Web",
                            "username_changes": { "count": "0" }
                        }
                    }
                }
            }
        });
        let p = parse(&v).unwrap();
        assert_eq!(p.account_based_in.as_deref(), Some("United States"));
        assert_eq!(p.location_accurate, None);
        assert_eq!(p.source.as_deref(), Some("Web"));
        assert_eq!(p.username_changes, Some(0));
        assert!(p.affiliate_username.is_none());
        assert!(!p.is_blue_verified);
    }

    #[test]
    fn missing_result_errors() {
        let v = json!({ "data": {} });
        assert!(parse(&v).is_err());
    }
}
