use crate::model::User;
use serde_json::Value;

#[derive(Debug, Default)]
pub struct UserListPage {
    pub users: Vec<User>,
    pub next_cursor: Option<String>,
}

/// Walk a user-list timeline's instructions (`Favoriters`, `Followers`,
/// `Following` all share the shape) and collect the users, each with the bio
/// the row shows under the name, plus the bottom-cursor for pagination.
pub fn parse_user_list_instructions(instructions: &[Value]) -> UserListPage {
    let mut page = UserListPage::default();
    for instr in instructions {
        let instr_type = instr.get("type").and_then(Value::as_str).unwrap_or("");
        if !matches!(instr_type, "TimelineAddEntries" | "TimelineReplaceEntry") {
            continue;
        }
        let Some(entries) = instr.get("entries").and_then(Value::as_array) else {
            continue;
        };
        for entry in entries {
            let entry_id = entry.get("entryId").and_then(Value::as_str).unwrap_or("");
            if entry_id.starts_with("cursor-bottom-") {
                if let Some(v) = entry.pointer("/content/value").and_then(Value::as_str) {
                    page.next_cursor = Some(v.to_string());
                }
                continue;
            }
            if entry_id.starts_with("cursor-top-") {
                continue;
            }
            let user_result = entry
                .pointer("/content/itemContent/user_results/result")
                .or_else(|| entry.pointer("/content/item/itemContent/user_results/result"));
            let Some(user_result) = user_result else {
                continue;
            };
            if let Some(u) = parse_profile_result(user_result) {
                page.users.push(u);
            }
        }
    }
    page
}

pub fn parse_user_result(node: &Value) -> Option<User> {
    let rest_id = node.get("rest_id").and_then(Value::as_str)?.to_string();

    let handle = node
        .pointer("/core/screen_name")
        .or_else(|| node.pointer("/legacy/screen_name"))
        .and_then(Value::as_str)?
        .to_string();

    let name = node
        .pointer("/core/name")
        .or_else(|| node.pointer("/legacy/name"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let verified = node
        .get("is_blue_verified")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || node
            .pointer("/legacy/verified")
            .and_then(Value::as_bool)
            .unwrap_or(false);

    let followers = node
        .pointer("/relationship_counts/followers")
        .or_else(|| node.pointer("/legacy/followers_count"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let following = node
        .pointer("/relationship_counts/following")
        .or_else(|| node.pointer("/legacy/friends_count"))
        .and_then(Value::as_u64)
        .unwrap_or(0);

    let avatar_url = node
        .pointer("/avatar/image_url")
        .or_else(|| node.pointer("/legacy/profile_image_url_https"))
        .and_then(Value::as_str)
        .map(|s| s.replace("_normal.", "_400x400."));

    let followed_by_me = node
        .pointer("/relationship_perspectives/following")
        .or_else(|| node.pointer("/legacy/following"))
        .and_then(Value::as_bool);

    let banner_url = node
        .pointer("/banner/image_url")
        .or_else(|| node.pointer("/legacy/profile_banner_url"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(banner_at_header_size);

    Some(User {
        rest_id,
        handle,
        name,
        verified,
        followers,
        following,
        avatar_url,
        followed_by_me,
        banner_url,
        description: None,
        location: None,
        website: None,
        joined_at: None,
        protected: false,
        muting: None,
        blocking: None,
    })
}

/// A user as a profile header shows them: [`parse_user_result`] plus the bio,
/// location, website, join date, protection and whether the signed-in user
/// mutes or blocks them. Kept apart so every post's author doesn't carry a
/// bio through timelines and the Home buffer.
pub fn parse_profile_result(node: &Value) -> Option<User> {
    let mut user = parse_user_result(node)?;
    user.description = node
        .pointer("/legacy/description")
        .or_else(|| node.pointer("/profile_bio/description"))
        .and_then(Value::as_str)
        .map(|bio| expand_links(bio, node.pointer("/legacy/entities/description/urls")))
        .and_then(non_empty);
    user.location = node
        .pointer("/location/location")
        .or_else(|| node.pointer("/legacy/location"))
        .and_then(Value::as_str)
        .and_then(|s| non_empty(s.trim().to_string()));
    user.website = node
        .pointer("/legacy/entities/url/urls/0/expanded_url")
        .and_then(Value::as_str)
        .and_then(|s| non_empty(s.to_string()));
    user.joined_at = node
        .pointer("/core/created_at")
        .or_else(|| node.pointer("/legacy/created_at"))
        .and_then(Value::as_str)
        .and_then(joined_at_rfc3339);
    user.protected = node
        .pointer("/privacy/protected")
        .or_else(|| node.pointer("/legacy/protected"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let relationship = |key: &str| {
        node.pointer(&format!("/relationship_perspectives/{key}"))
            .or_else(|| node.pointer(&format!("/legacy/{key}")))
            .and_then(Value::as_bool)
    };
    user.muting = relationship("muting");
    user.blocking = relationship("blocking");
    Some(user)
}

fn non_empty(s: String) -> Option<String> {
    (!s.is_empty()).then_some(s)
}

/// A bio's links arrive as t.co short links, with the real address beside
/// them in `entities.description.urls`.
fn expand_links(text: &str, urls: Option<&Value>) -> String {
    let mut out = crate::parse::tweet::decode_html_entities(text);
    for u in urls.and_then(Value::as_array).into_iter().flatten() {
        let short = u.get("url").and_then(Value::as_str).unwrap_or("");
        let full = u.get("expanded_url").and_then(Value::as_str).unwrap_or("");
        if !short.is_empty() && !full.is_empty() {
            out = out.replace(short, full);
        }
    }
    out.trim().to_string()
}

/// X dates accounts like `Wed Oct 10 20:19:24 +0000 2018`.
fn joined_at_rfc3339(raw: &str) -> Option<String> {
    chrono::DateTime::parse_from_str(raw, "%a %b %d %H:%M:%S %z %Y")
        .ok()
        .map(|dt| {
            dt.with_timezone(&chrono::Utc)
                .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
        })
}

/// X serves a banner at `…/profile_banners/<id>/<stamp>` and resizes it when a
/// size is appended; the widest one is 1500×500.
fn banner_at_header_size(url: &str) -> String {
    let base = url.trim_end_matches('/');
    let last = base.rsplit('/').next().unwrap_or("");
    let sized = last.contains('x') && last.chars().all(|c| c.is_ascii_digit() || c == 'x');
    if sized {
        base.to_string()
    } else {
        format!("{base}/1500x500")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn user_entry(entry_id: &str, rest_id: &str, handle: &str) -> Value {
        json!({
            "entryId": entry_id,
            "content": {
                "itemContent": {
                    "user_results": {
                        "result": {
                            "rest_id": rest_id,
                            "is_blue_verified": false,
                            "core": { "screen_name": handle, "name": handle },
                            "legacy": { "followers_count": 10, "friends_count": 5 }
                        }
                    }
                }
            }
        })
    }

    #[test]
    fn user_list_collects_users_and_bottom_cursor() {
        let instructions = vec![json!({
            "type": "TimelineAddEntries",
            "entries": [
                user_entry("user-1", "1", "alice"),
                user_entry("user-2", "2", "bob"),
                {
                    "entryId": "cursor-top-0",
                    "content": { "value": "TOP" }
                },
                {
                    "entryId": "cursor-bottom-0",
                    "content": { "value": "BOTTOM" }
                }
            ]
        })];
        let page = parse_user_list_instructions(&instructions);
        assert_eq!(page.users.len(), 2);
        assert_eq!(page.users[0].handle, "alice");
        assert_eq!(page.users[1].rest_id, "2");
        assert_eq!(page.next_cursor.as_deref(), Some("BOTTOM"));
    }

    #[test]
    fn user_list_rows_carry_the_bio_with_links_expanded() {
        let mut entry = user_entry("user-1", "1", "alice");
        entry["content"]["itemContent"]["user_results"]["result"]["legacy"] = json!({
            "description": "builds things https://t.co/abc",
            "entities": { "description": { "urls": [
                { "url": "https://t.co/abc", "expanded_url": "https://example.com" }
            ] } }
        });
        let instructions = vec![json!({ "type": "TimelineAddEntries", "entries": [entry] })];
        let page = parse_user_list_instructions(&instructions);
        assert_eq!(
            page.users[0].description.as_deref(),
            Some("builds things https://example.com")
        );
    }

    #[test]
    fn user_list_reads_nested_item_shape_and_skips_junk() {
        let instructions = vec![json!({
            "type": "TimelineReplaceEntry",
            "entries": [
                {
                    "entryId": "user-9",
                    "content": {
                        "item": {
                            "itemContent": {
                                "user_results": {
                                    "result": {
                                        "rest_id": "9",
                                        "core": { "screen_name": "carol", "name": "Carol" },
                                        "legacy": {}
                                    }
                                }
                            }
                        }
                    }
                },
                { "entryId": "who-to-follow-junk", "content": {} }
            ]
        })];
        let page = parse_user_list_instructions(&instructions);
        assert_eq!(page.users.len(), 1);
        assert_eq!(page.users[0].handle, "carol");
        assert!(page.next_cursor.is_none());
    }

    #[test]
    fn follower_counts_come_from_relationship_counts_with_a_legacy_fallback() {
        let current = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "relationship_counts": { "followers": 241_723_845u64, "following": 1414 },
            "legacy": {}
        });
        let user = parse_user_result(&current).unwrap();
        assert_eq!((user.followers, user.following), (241_723_845, 1414));

        let older = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "legacy": { "followers_count": 10, "friends_count": 5 }
        });
        let user = parse_user_result(&older).unwrap();
        assert_eq!((user.followers, user.following), (10, 5));
    }

    #[test]
    fn banner_is_read_at_header_size() {
        let node = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "banner": { "image_url": "https://pbs.twimg.com/profile_banners/7/1700000000" },
            "legacy": {}
        });
        assert_eq!(
            parse_user_result(&node).unwrap().banner_url.as_deref(),
            Some("https://pbs.twimg.com/profile_banners/7/1700000000/1500x500")
        );
        let sized = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "legacy": { "profile_banner_url": "https://pbs.twimg.com/profile_banners/7/1700000000/600x200" }
        });
        assert_eq!(
            parse_user_result(&sized).unwrap().banner_url.as_deref(),
            Some("https://pbs.twimg.com/profile_banners/7/1700000000/600x200")
        );
        let none = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "legacy": {}
        });
        assert_eq!(parse_user_result(&none).unwrap().banner_url, None);
    }

    #[test]
    fn user_result_parses_followed_by_me_from_relationship_perspectives() {
        let node = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "relationship_perspectives": { "following": true },
            "legacy": { "followers_count": 1, "friends_count": 2 }
        });
        let user = parse_user_result(&node).unwrap();
        assert_eq!(user.followed_by_me, Some(true));
    }

    #[test]
    fn user_result_parses_followed_by_me_from_legacy_and_absent() {
        let node = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "legacy": { "followers_count": 1, "friends_count": 2, "following": false }
        });
        assert_eq!(
            parse_user_result(&node).unwrap().followed_by_me,
            Some(false)
        );
        let bare = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "legacy": {}
        });
        assert_eq!(parse_user_result(&bare).unwrap().followed_by_me, None);
    }

    #[test]
    fn profile_fields_are_read_from_the_legacy_shape() {
        let node = json!({
            "rest_id": "7",
            "legacy": {
                "screen_name": "bob",
                "name": "Bob",
                "description": "Writes about rust &amp; tea. Blog: https://t.co/abc and https://t.co/def",
                "location": " Helsinki ",
                "created_at": "Wed Oct 10 20:19:24 +0000 2018",
                "protected": true,
                "muting": false,
                "blocking": true,
                "entities": {
                    "description": { "urls": [
                        { "url": "https://t.co/abc", "expanded_url": "https://bob.example/blog", "display_url": "bob.example/blog" },
                        { "url": "https://t.co/def", "expanded_url": "https://bob.example/tea", "display_url": "bob.example/tea" }
                    ] },
                    "url": { "urls": [
                        { "url": "https://t.co/xyz", "expanded_url": "https://bob.example", "display_url": "bob.example" }
                    ] }
                }
            }
        });
        let user = parse_profile_result(&node).unwrap();
        assert_eq!(
            user.description.as_deref(),
            Some(
                "Writes about rust & tea. Blog: https://bob.example/blog and https://bob.example/tea"
            )
        );
        assert_eq!(user.location.as_deref(), Some("Helsinki"));
        assert_eq!(user.website.as_deref(), Some("https://bob.example"));
        assert_eq!(user.joined_at.as_deref(), Some("2018-10-10T20:19:24Z"));
        assert!(user.protected);
        assert_eq!(user.muting, Some(false));
        assert_eq!(user.blocking, Some(true));
    }

    #[test]
    fn profile_fields_are_read_from_the_current_shape() {
        let node = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob", "created_at": "Wed Oct 10 20:19:24 +0000 2018" },
            "location": { "location": "Turku" },
            "privacy": { "protected": false },
            "relationship_perspectives": { "following": true, "muting": true, "blocking": false },
            "profile_bio": { "description": "hello" },
            "legacy": {}
        });
        let user = parse_profile_result(&node).unwrap();
        assert_eq!(user.description.as_deref(), Some("hello"));
        assert_eq!(user.location.as_deref(), Some("Turku"));
        assert_eq!(user.joined_at.as_deref(), Some("2018-10-10T20:19:24Z"));
        assert!(!user.protected);
        assert_eq!((user.muting, user.blocking), (Some(true), Some(false)));
    }

    #[test]
    fn missing_profile_fields_stay_off_the_wire() {
        let node = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "legacy": { "description": "", "location": "", "created_at": "not a date" }
        });
        let user = parse_profile_result(&node).unwrap();
        let v = serde_json::to_value(&user).unwrap();
        for key in [
            "description",
            "location",
            "website",
            "joined_at",
            "protected",
            "muting",
            "blocking",
        ] {
            assert!(v.get(key).is_none(), "{key}");
        }
    }

    #[test]
    fn post_authors_carry_no_profile_fields() {
        let node = json!({
            "rest_id": "7",
            "core": { "screen_name": "bob", "name": "Bob" },
            "legacy": { "description": "a bio", "location": "Turku", "protected": true }
        });
        let user = parse_user_result(&node).unwrap();
        assert_eq!((user.description, user.location), (None, None));
        assert!(!user.protected);
    }

    #[test]
    fn user_list_ignores_unrelated_instruction_types() {
        let instructions = vec![json!({ "type": "TimelineClearCache" })];
        let page = parse_user_list_instructions(&instructions);
        assert!(page.users.is_empty());
        assert!(page.next_cursor.is_none());
    }
}
