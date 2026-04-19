use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::tweet as parse_tweet;
use crate::server::error::ApiError;
use crate::server::state::AppState;
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use std::sync::Arc;
use unrager_model::MediaKind;

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
