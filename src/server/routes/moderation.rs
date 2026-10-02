use crate::server::error::ApiError;
use crate::server::routes::posts::{numeric_id, x_error_code};
use crate::server::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use serde_json::{Value, json};
use std::sync::Arc;

/// X's code for unmuting an account that isn't muted.
const NOT_MUTING: i64 = 272;

/// Mute and block, as x.com does them: legacy 1.1 form posts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Action {
    Mute,
    Unmute,
    Block,
    Unblock,
}

impl Action {
    fn path(self) -> &'static str {
        match self {
            Self::Mute => "/i/api/1.1/mutes/users/create.json",
            Self::Unmute => "/i/api/1.1/mutes/users/destroy.json",
            Self::Block => "/i/api/1.1/blocks/create.json",
            Self::Unblock => "/i/api/1.1/blocks/destroy.json",
        }
    }

    /// The response key naming the state this action changes.
    fn key(self) -> &'static str {
        match self {
            Self::Mute | Self::Unmute => "muting",
            Self::Block | Self::Unblock => "blocking",
        }
    }

    fn turns_on(self) -> bool {
        matches!(self, Self::Mute | Self::Block)
    }

    /// X answers some "already so" requests with an error: the end state
    /// holds, so they count as done.
    fn already_done(self, code: Option<i64>) -> bool {
        self == Self::Unmute && code == Some(NOT_MUTING)
    }
}

pub async fn mute(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<String>,
) -> std::result::Result<Json<Value>, ApiError> {
    apply(&state, &user_id, Action::Mute).await
}

pub async fn unmute(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<String>,
) -> std::result::Result<Json<Value>, ApiError> {
    apply(&state, &user_id, Action::Unmute).await
}

pub async fn block(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<String>,
) -> std::result::Result<Json<Value>, ApiError> {
    apply(&state, &user_id, Action::Block).await
}

pub async fn unblock(
    State(state): State<Arc<AppState>>,
    Path(user_id): Path<String>,
) -> std::result::Result<Json<Value>, ApiError> {
    apply(&state, &user_id, Action::Unblock).await
}

async fn apply(
    state: &AppState,
    user_id: &str,
    action: Action,
) -> std::result::Result<Json<Value>, ApiError> {
    let id = numeric_id(user_id).ok_or_else(|| ApiError::bad_request("not a user id"))?;
    match state
        .gql
        .post_form_1_1(action.path(), &[("user_id", id)])
        .await
    {
        Ok(_) => {}
        Err(e) if action.already_done(x_error_code(&e)) => {}
        Err(e) => return Err(e.into()),
    }
    tracing::info!(user = %id, ?action, "account moderated");
    Ok(Json(answer(action)))
}

/// `{"ok": true, "muting"|"blocking": bool}`. X's reply is a user object
/// whose flags can predate the change, so the answer is the state the
/// action asked for, which holds once X accepted it.
fn answer(action: Action) -> Value {
    json!({ "ok": true, action.key(): action.turns_on() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_name_the_state_each_action_leaves() {
        assert_eq!(answer(Action::Mute), json!({ "ok": true, "muting": true }));
        assert_eq!(
            answer(Action::Unmute),
            json!({ "ok": true, "muting": false })
        );
        assert_eq!(
            answer(Action::Block),
            json!({ "ok": true, "blocking": true })
        );
        assert_eq!(
            answer(Action::Unblock),
            json!({ "ok": true, "blocking": false })
        );
    }

    #[test]
    fn unmuting_someone_not_muted_is_done_already() {
        assert!(Action::Unmute.already_done(Some(NOT_MUTING)));
        assert!(!Action::Mute.already_done(Some(NOT_MUTING)));
        assert!(!Action::Unmute.already_done(None));
    }

    #[test]
    fn each_action_posts_to_its_endpoint() {
        assert_eq!(Action::Mute.path(), "/i/api/1.1/mutes/users/create.json");
        assert_eq!(Action::Unblock.path(), "/i/api/1.1/blocks/destroy.json");
    }
}
