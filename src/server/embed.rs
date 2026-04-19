use axum::body::Body;
use axum::http::{StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "crates/unrager-app/dist/"]
#[prefix = ""]
struct WebAssets;

pub async fn serve_static(uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    if path.starts_with("api/") {
        return (StatusCode::NOT_FOUND, "not found").into_response();
    }

    let effective = if path.is_empty() { "index.html" } else { path };

    if let Some(file) = WebAssets::get(effective) {
        let mime = mime_guess::from_path(effective).first_or_octet_stream();
        return Response::builder()
            .header(header::CONTENT_TYPE, mime.as_ref())
            .header(header::CACHE_CONTROL, cache_header(effective))
            .body(Body::from(file.data.into_owned()))
            .unwrap();
    }

    if let Some(file) = WebAssets::get("index.html") {
        return Response::builder()
            .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
            .header(header::CACHE_CONTROL, "no-cache")
            .body(Body::from(file.data.into_owned()))
            .unwrap();
    }

    (
        StatusCode::NOT_FOUND,
        "Web assets not built. Run `just web` or `dx bundle --platform web --release -p unrager-app` and retry.",
    )
        .into_response()
}

fn cache_header(path: &str) -> &'static str {
    if path.ends_with(".wasm") || path.ends_with(".js") || path.ends_with(".css") {
        "public, max-age=31536000, immutable"
    } else if path == "index.html" || path.ends_with(".html") {
        "no-cache"
    } else {
        "public, max-age=3600"
    }
}
