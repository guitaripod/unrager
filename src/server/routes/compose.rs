use crate::api::{ApiClient, MediaFile};
use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::extract::{Multipart, Path, State};
use std::io::Write;
use std::sync::Arc;
use tempfile::NamedTempFile;

pub async fn compose(
    State(_state): State<Arc<AppState>>,
    multipart: Multipart,
) -> std::result::Result<Json<unrager_model::ComposeResult>, ApiError> {
    do_compose(multipart, None).await
}

pub async fn reply(
    State(_state): State<Arc<AppState>>,
    Path(tweet_id): Path<String>,
    multipart: Multipart,
) -> std::result::Result<Json<unrager_model::ComposeResult>, ApiError> {
    do_compose(multipart, Some(tweet_id)).await
}

async fn do_compose(
    mut multipart: Multipart,
    in_reply_to: Option<String>,
) -> std::result::Result<Json<unrager_model::ComposeResult>, ApiError> {
    let mut text = String::new();
    let mut media_paths: Vec<NamedTempFile> = Vec::new();

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError::bad_request(e.to_string()))?
    {
        let name = field.name().map(str::to_string).unwrap_or_default();
        match name.as_str() {
            "text" => {
                text = field
                    .text()
                    .await
                    .map_err(|e| ApiError::bad_request(e.to_string()))?;
            }
            "media" | "media[]" => {
                let filename = field
                    .file_name()
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("upload-{}.bin", media_paths.len()));
                let bytes = field
                    .bytes()
                    .await
                    .map_err(|e| ApiError::bad_request(e.to_string()))?;
                let ext = std::path::Path::new(&filename)
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("bin");
                let mut tmp = tempfile::Builder::new()
                    .prefix("unrager-upload-")
                    .suffix(&format!(".{ext}"))
                    .tempfile()
                    .map_err(|e| ApiError::internal(e.to_string()))?;
                tmp.as_file_mut()
                    .write_all(&bytes)
                    .map_err(|e| ApiError::internal(e.to_string()))?;
                media_paths.push(tmp);
            }
            _ => {}
        }
    }

    if text.trim().is_empty() && media_paths.is_empty() {
        return Err(ApiError::bad_request("text or media required"));
    }

    let files: Vec<MediaFile> = media_paths
        .iter()
        .map(|t| MediaFile::from_path(t.path()))
        .collect::<crate::error::Result<Vec<_>>>()?;

    let api = ApiClient::new().await?;
    let posted = api
        .post_with_media(&text, in_reply_to.as_deref(), &files)
        .await?;

    Ok(Json(unrager_model::ComposeResult {
        url: posted.url(),
        id: posted.id,
        idempotent: false,
    }))
}
