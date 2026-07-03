use crate::model::User;
use serde_json::Value;

#[derive(Debug, Default)]
pub struct UserListPage {
    pub users: Vec<User>,
    pub next_cursor: Option<String>,
}

/// Walk a user-list timeline's instructions (`Favoriters`, `Followers`,
/// `Following` all share the shape) and collect the users plus the
/// bottom-cursor for pagination.
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
            if let Some(u) = parse_user_result(user_result) {
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
        .pointer("/legacy/followers_count")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let following = node
        .pointer("/legacy/friends_count")
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

    Some(User {
        rest_id,
        handle,
        name,
        verified,
        followers,
        following,
        avatar_url,
        followed_by_me,
    })
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
    fn user_list_ignores_unrelated_instruction_types() {
        let instructions = vec![json!({ "type": "TimelineClearCache" })];
        let page = parse_user_list_instructions(&instructions);
        assert!(page.users.is_empty());
        assert!(page.next_cursor.is_none());
    }
}
