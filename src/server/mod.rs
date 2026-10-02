pub mod error;
pub mod llm;
pub mod routes;
pub mod sse;
pub mod state;

use axum::Router;
use axum::extract::{Request, State};
use axum::http::{HeaderValue, StatusCode, Uri, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use state::AppState;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::TcpListener;
use tower_http::compression::CompressionLayer;
use tower_http::trace::TraceLayer;

pub use error::ApiError;

const VERSION_HEADER: &str = "x-unrager-version";

pub async fn serve(addr: SocketAddr, filter_only: bool) -> crate::error::Result<()> {
    let state = Arc::new(AppState::build(filter_only).await?);
    if !filter_only {
        let warm_client = state.gql.clone();
        tokio::spawn(async move { warm_client.warm_transaction_key().await });
    }
    write_lockfile(&state)?;
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    if state.x_session_loaded {
        spawn_ingest(&state, shutdown_rx).await;
    }
    spawn_housekeeping(&state);
    let app = router(state.clone());

    if filter_only {
        tracing::info!("unrager filter server listening on http://{addr} (filter only)");
    } else {
        tracing::info!("unrager server listening on http://{addr}");
    }

    let listener = TcpListener::bind(addr)
        .await
        .map_err(|e| crate::error::Error::Config(format!("bind {addr}: {e}")))?;

    let cleanup_state = state.clone();
    let shutdown = async move {
        wait_for_shutdown().await;
        let _ = shutdown_tx.send(true);
        remove_lockfile(&cleanup_state);
    };

    axum::serve(listener, app.into_make_service())
        .with_graceful_shutdown(shutdown)
        .await
        .map_err(|e| crate::error::Error::Config(format!("serve: {e}")))?;

    Ok(())
}

/// Daily pruning for a server that stays up for weeks: `open` only prunes
/// expired filter verdicts and read marks at startup, so without this both
/// tables and their in-memory copies would grow for as long as it runs.
fn spawn_housekeeping(state: &Arc<AppState>) {
    let state = state.clone();
    tokio::spawn(async move {
        let mut daily = tokio::time::interval(std::time::Duration::from_secs(24 * 3600));
        daily.tick().await;
        loop {
            daily.tick().await;
            if let Err(e) = state.filter_cache.lock().await.prune() {
                tracing::warn!("filter cache prune failed: {e}");
            }
            if let Err(e) = state.seen.lock().await.prune() {
                tracing::warn!("seen store prune failed: {e}");
            }
        }
    });
}

/// Take the feed-writer lock and launch the background ingest worker. If
/// another process (a second serve, or a TUI) already owns the lock, this
/// process just serves read-only from the shared `feed.db`.
async fn spawn_ingest(state: &Arc<AppState>, shutdown_rx: tokio::sync::watch::Receiver<bool>) {
    match crate::store::feed::FeedStore::open_writer(&state.feed_db_path) {
        Ok(Some(store)) => {
            let classifier = state.classifier.lock().await.handle();
            tokio::spawn(crate::store::ingest::run(
                state.gql.clone(),
                classifier,
                state.filter_cache.clone(),
                store,
                state.feed_cfg.clone(),
                state.activity.clone(),
                shutdown_rx,
            ));
            tracing::info!("feed ingest worker owns the writer lock");
        }
        Ok(None) => {
            tracing::info!("feed writer lock held elsewhere; serving read-only from feed.db");
        }
        Err(e) => tracing::warn!("failed to open feed store for writing: {e}"),
    }
}

/// Everything the browser extension needs. Always served, including under
/// `--filter-only`.
fn filter_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/health", get(routes::health::health))
        .route("/classify", post(routes::classify::classify))
        .route("/filter/status", get(routes::classify::status))
        .route("/filter/warm", post(routes::classify::warm))
        .route("/filter/stats", get(routes::filter::stats))
        .route("/filter/overrides", post(routes::filter::set_overrides))
        .route(
            "/config/filter",
            get(routes::config::get_filter).patch(routes::config::patch_filter),
        )
}

async fn reject_when_filter_only(
    State(state): State<Arc<AppState>>,
    request: Request,
    next: Next,
) -> Response {
    if state.filter_only {
        return ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "filter_only",
            "this unrager server runs with --filter-only (all the browser extension needs); \
             run `unrager setup --apps` to serve the iPhone app too",
        )
        .into_response();
    }
    next.run(request).await
}

/// Browsers attach `Origin` to every cross-site request and to any
/// non-GET same-site one. The browser extension's requests carry its own
/// extension origin and the native apps send none, so anything else is a web
/// page trying to drive this server through its visitor's browser (post as
/// them, rewrite their rules) and is refused.
async fn reject_web_origins(request: Request, next: Next) -> Response {
    match request.headers().get(header::ORIGIN) {
        Some(origin) if !is_extension_origin(origin) => ApiError::new(
            StatusCode::FORBIDDEN,
            "forbidden_origin",
            "unrager only answers its browser extension and the iPhone app, not web pages",
        )
        .into_response(),
        _ => next.run(request).await,
    }
}

/// Tells every client which unrager answered, so the browser extension can
/// flag a version it no longer matches without polling for it.
async fn stamp_version(mut response: Response) -> Response {
    response.headers_mut().insert(
        VERSION_HEADER,
        HeaderValue::from_static(env!("CARGO_PKG_VERSION")),
    );
    response
}

fn is_extension_origin(origin: &HeaderValue) -> bool {
    let origin = origin.to_str().unwrap_or_default();
    [
        "chrome-extension://",
        "moz-extension://",
        "safari-web-extension://",
    ]
    .iter()
    .any(|scheme| origin.starts_with(scheme))
}

fn router(state: Arc<AppState>) -> Router {
    let app_routes = app_routes().route_layer(middleware::from_fn_with_state(
        state.clone(),
        reject_when_filter_only,
    ));
    let api = filter_routes().merge(app_routes);

    Router::new()
        .nest("/api", api)
        .fallback(fallback)
        .layer(middleware::from_fn(error::json_errors))
        .layer(axum::extract::DefaultBodyLimit::max(64 * 1024 * 1024))
        .layer(CompressionLayer::new())
        .layer(middleware::from_fn(reject_web_origins))
        .layer(middleware::map_response(stamp_version))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// Everything the iPhone app uses beyond the filter; `router` closes it to
/// `--filter-only` servers.
fn app_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/whoami", get(routes::whoami::whoami))
        .route("/sources/home", get(routes::timeline::home))
        .route("/sources/user/{handle}", get(routes::timeline::user))
        .route(
            "/sources/user/{handle}/replies",
            get(routes::timeline::user_replies),
        )
        .route("/sources/search", get(routes::timeline::search))
        .route(
            "/sources/search/people",
            get(routes::timeline::search_people),
        )
        .route("/sources/mentions", get(routes::timeline::mentions))
        .route("/sources/bookmarks", get(routes::timeline::bookmarks))
        .route(
            "/sources/notifications",
            get(routes::timeline::notifications),
        )
        .route("/feed/status", get(routes::feed::status))
        .route("/tweet/{id}", get(routes::tweet::single))
        .route(
            "/tweets/{tweet_id}/analytics",
            get(routes::tweet::analytics),
        )
        .route("/tweets/{tweet_id}", delete(routes::posts::delete))
        .route("/tweets/{tweet_id}/quotes", get(routes::posts::quotes))
        .route("/thread/{id}", get(routes::tweet::thread))
        .route("/about/{rest_id}", get(routes::about::about))
        .route("/profile/{handle}", get(routes::profile::profile))
        .route("/likers/{tweet_id}", get(routes::profile::likers))
        .route("/engage/{tweet_id}/like", post(routes::engage::like))
        .route("/engage/{tweet_id}/unlike", post(routes::engage::unlike))
        .route(
            "/tweets/{tweet_id}/retweet",
            post(routes::engage::retweet).delete(routes::engage::unretweet),
        )
        .route(
            "/tweets/{tweet_id}/bookmark",
            post(routes::engage::bookmark).delete(routes::engage::unbookmark),
        )
        .route(
            "/users/{user_id}/follow",
            post(routes::users::follow).delete(routes::users::unfollow),
        )
        .route(
            "/users/{user_id}/mute",
            post(routes::moderation::mute).delete(routes::moderation::unmute),
        )
        .route(
            "/users/{user_id}/block",
            post(routes::moderation::block).delete(routes::moderation::unblock),
        )
        .route("/users/{user_id}/followers", get(routes::users::followers))
        .route("/users/{user_id}/following", get(routes::users::following))
        .route("/compose", post(routes::compose::compose))
        .route("/reply/{tweet_id}", post(routes::compose::reply))
        .route("/media/upload", post(routes::media::upload))
        .route(
            "/seen",
            get(routes::seen::list)
                .post(routes::seen::mark)
                .delete(routes::seen::clear),
        )
        .route("/seen/{id}", get(routes::seen::check))
        .route(
            "/notifications/seen",
            get(routes::seen::notifications_seen_get).put(routes::seen::notifications_seen_put),
        )
        .route(
            "/session",
            get(routes::session::get).patch(routes::session::patch),
        )
        .route("/media/{tweet_id}/{index}", get(routes::media::proxy))
        .route("/sse/filter", get(sse::filter_stream))
        .route(
            "/sse/ask",
            get(sse::ask_stream).post(sse::ask_context_stream),
        )
        .route("/sse/brief", get(sse::brief_stream))
        .route("/sse/translate", get(sse::translate_stream))
}

async fn fallback(uri: Uri) -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        format!(
            "unrager is an API-only server — no route for {}. The API lives under /api.",
            uri.path()
        ),
    )
}

fn write_lockfile(state: &AppState) -> crate::error::Result<()> {
    let path = state.lock_path.clone();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, std::process::id().to_string()).map_err(|e| {
        crate::error::Error::Config(format!("write lockfile {}: {e}", path.display()))
    })?;
    Ok(())
}

fn remove_lockfile(state: &AppState) {
    let _ = std::fs::remove_file(&state.lock_path);
}

async fn wait_for_shutdown() {
    use tokio::signal;
    let ctrl_c = async {
        let _ = signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        let _ = signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("sigterm handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {}
        _ = term => {}
    }
    tracing::info!("shutdown signal received");
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use tower::Service;

    async fn status_for(origin: Option<&str>) -> StatusCode {
        let mut app = Router::new()
            .route("/api/health", get(|| async { "ok" }))
            .layer(middleware::from_fn(reject_web_origins));
        let mut request = axum::http::Request::builder().uri("/api/health");
        if let Some(origin) = origin {
            request = request.header(header::ORIGIN, origin);
        }
        app.call(request.body(Body::empty()).unwrap())
            .await
            .unwrap()
            .status()
    }

    #[test]
    fn every_route_registers_without_a_conflict() {
        let _ = filter_routes().merge(app_routes());
    }

    #[tokio::test]
    async fn web_pages_are_refused_but_the_extension_and_apps_are_not() {
        assert_eq!(status_for(None).await, StatusCode::OK);
        assert_eq!(
            status_for(Some("chrome-extension://abcdefghijklmnopabcdefghijklmnop")).await,
            StatusCode::OK
        );
        assert_eq!(
            status_for(Some("moz-extension://1234")).await,
            StatusCode::OK
        );
        for origin in ["https://evil.example", "null", "http://localhost:7777"] {
            assert_eq!(
                status_for(Some(origin)).await,
                StatusCode::FORBIDDEN,
                "{origin}"
            );
        }
    }
}
