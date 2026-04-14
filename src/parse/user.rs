use crate::model::User;
use serde_json::Value;

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

    Some(User {
        rest_id,
        handle,
        name,
        verified,
        followers,
        following,
    })
}
