use crate::error::{Error, Result};
use serde_json::Value;

#[derive(Debug, Clone)]
pub struct ViewerInfo {
    pub user_id: String,
    pub handle: String,
    pub name: String,
}

pub fn parse(response: &Value) -> Result<ViewerInfo> {
    let result = response
        .pointer("/data/viewer/user_results/result")
        .or_else(|| response.pointer("/data/viewer_v2/user_results/result"))
        .ok_or_else(|| Error::GraphqlShape("missing viewer.user_results.result".into()))?;

    let user_id = result
        .get("rest_id")
        .and_then(Value::as_str)
        .ok_or_else(|| Error::GraphqlShape("missing viewer rest_id".into()))?
        .to_string();

    let handle = find_string(result, &["/core/screen_name", "/legacy/screen_name"])
        .ok_or_else(|| Error::GraphqlShape("missing screen_name".into()))?;

    let name = find_string(result, &["/core/name", "/legacy/name"]).unwrap_or_default();

    Ok(ViewerInfo {
        user_id,
        handle,
        name,
    })
}

fn find_string(value: &Value, pointers: &[&str]) -> Option<String> {
    for ptr in pointers {
        if let Some(s) = value.pointer(ptr).and_then(Value::as_str) {
            return Some(s.to_string());
        }
    }
    None
}
