use crate::api::{ApiClient, MediaFile};
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::tweet as parse_tweet;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::Json;
use axum::body::{Body, Bytes};
use axum::extract::{FromRequest, Multipart, Path, Request, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use std::io::Write;
use std::sync::Arc;
use unrager_model::{MediaKind, MediaUploadResult};

pub async fn proxy(
    State(state): State<Arc<AppState>>,
    Path((tweet_id, index)): Path<(String, usize)>,
) -> std::result::Result<Response, ApiError> {
    let response = state
        .gql
        .get(
            Operation::TweetResultByRestId,
            &endpoints::tweet_by_rest_id_variables(&tweet_id),
            &endpoints::tweet_read_features(),
        )
        .await?;
    let tweet = parse_tweet::parse_tweet_result_by_rest_id(&response)?;
    let media = tweet
        .media
        .get(index)
        .ok_or_else(|| ApiError::not_found("media index out of range"))?;

    let url = match &media.kind {
        MediaKind::Video | MediaKind::AnimatedGif => {
            media.video_url.as_deref().unwrap_or(&media.url)
        }
        _ => media.url.as_str(),
    };

    let upstream = reqwest::Client::new()
        .get(url)
        .send()
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    if !upstream.status().is_success() {
        return Ok((
            StatusCode::from_u16(upstream.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY),
            "upstream error",
        )
            .into_response());
    }

    let content_type = upstream
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
        .unwrap_or_else(|| guess_mime(url).to_string());

    let mut builder = Response::builder()
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CACHE_CONTROL, "public, max-age=604800");
    if let Some(len) = upstream.headers().get(header::CONTENT_LENGTH) {
        builder = builder.header(header::CONTENT_LENGTH, len);
    }
    let body = Body::from_stream(upstream.bytes_stream());
    Ok(builder.body(body).unwrap())
}

/// `POST /api/media/upload` — accepts a multipart form (field `media`,
/// `media[]`, or `file`) or a raw image/video body, uploads it to X via the
/// v2 media-upload API, and returns the media id for use in
/// `POST /api/compose` `media_ids`.
pub async fn upload(
    State(state): State<Arc<AppState>>,
    req: Request,
) -> std::result::Result<Json<MediaUploadResult>, ApiError> {
    let content_type = req
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_string();

    let (bytes, filename) = if content_type.starts_with("multipart/form-data") {
        let multipart = Multipart::from_request(req, &())
            .await
            .map_err(|e| ApiError::bad_request(e.to_string()))?;
        extract_multipart_file(multipart).await?
    } else {
        let bytes = Bytes::from_request(req, &())
            .await
            .map_err(|e| ApiError::bad_request(e.to_string()))?;
        let name = format!("upload.{}", extension_for_mime(&content_type));
        (bytes, name)
    };

    if bytes.is_empty() {
        return Err(ApiError::bad_request("empty media body"));
    }

    let ext = std::path::Path::new(&filename)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("bin");
    let mut tmp = tempfile::Builder::new()
        .prefix("unrager-media-upload-")
        .suffix(&format!(".{ext}"))
        .tempfile()
        .map_err(|e| ApiError::internal(e.to_string()))?;
    tmp.as_file_mut()
        .write_all(&bytes)
        .map_err(|e| ApiError::internal(e.to_string()))?;

    let file = MediaFile::from_path(tmp.path())?;
    let media_id = upload_via_best_path(&state, &file, &bytes).await?;
    tracing::info!(
        media_id,
        size = bytes.len(),
        "media uploaded via /api/media/upload"
    );
    Ok(Json(MediaUploadResult { media_id }))
}

/// Prefer the official OAuth2 v2 upload when developer credentials are
/// configured (matching the compose path); otherwise — or when the v2 upload
/// fails — fall back to X's session-authenticated chunked upload, which needs
/// only the browser cookie session. Both mint media ids for the same account.
async fn upload_via_best_path(
    state: &Arc<AppState>,
    file: &MediaFile,
    bytes: &[u8],
) -> std::result::Result<String, ApiError> {
    if oauth_configured() {
        match upload_v2(file).await {
            Ok(id) => return Ok(id),
            Err(e) => {
                tracing::warn!("v2 media upload failed, using session upload: {e}");
            }
        }
    }
    Ok(state
        .gql
        .upload_media_session(bytes, &file.mime, file.category.as_api())
        .await?)
}

fn oauth_configured() -> bool {
    crate::auth::oauth::client_id().is_ok()
        && crate::auth::oauth::tokens_path()
            .map(|p| p.exists())
            .unwrap_or(false)
}

async fn upload_v2(file: &MediaFile) -> crate::error::Result<String> {
    let api = ApiClient::new().await?;
    api.upload_media(file).await
}

async fn extract_multipart_file(
    mut multipart: Multipart,
) -> std::result::Result<(Bytes, String), ApiError> {
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError::bad_request(e.to_string()))?
    {
        let name = field.name().unwrap_or_default();
        if !matches!(name, "media" | "media[]" | "file" | "") {
            continue;
        }
        let filename = field
            .file_name()
            .map(str::to_string)
            .or_else(|| {
                field
                    .content_type()
                    .map(|ct| format!("upload.{}", extension_for_mime(ct)))
            })
            .unwrap_or_else(|| "upload.bin".to_string());
        let bytes = field
            .bytes()
            .await
            .map_err(|e| ApiError::bad_request(e.to_string()))?;
        return Ok((bytes, filename));
    }
    Err(ApiError::bad_request(
        "multipart body has no media/file field",
    ))
}

fn extension_for_mime(mime: &str) -> &'static str {
    match mime.split(';').next().unwrap_or_default().trim() {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "video/mp4" => "mp4",
        "video/quicktime" => "mov",
        _ => "bin",
    }
}

fn guess_mime(url: &str) -> &'static str {
    let lower = url.to_lowercase();
    if lower.contains(".png") {
        "image/png"
    } else if lower.contains(".jpg") || lower.contains(".jpeg") {
        "image/jpeg"
    } else if lower.contains(".webp") {
        "image/webp"
    } else if lower.contains(".gif") {
        "image/gif"
    } else if lower.contains(".mp4") {
        "video/mp4"
    } else if lower.contains(".m3u8") {
        "application/vnd.apple.mpegurl"
    } else {
        "application/octet-stream"
    }
}
