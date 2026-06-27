pub mod error;
pub mod llm;
pub mod routes;
pub mod sse;
pub mod state;

use axum::Router;
use axum::http::{StatusCode, Uri};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use state::AppState;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::TcpListener;
use tower_http::compression::CompressionLayer;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

pub use error::ApiError;

pub async fn serve(addr: SocketAddr) -> crate::error::Result<()> {
    let state = Arc::new(AppState::build().await?);
    write_lockfile(&state)?;
    let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
    spawn_ingest(&state, shutdown_rx).await;
    let app = router(state.clone());

    tracing::info!("unrager server listening on http://{addr}");

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

fn router(state: Arc<AppState>) -> Router {
    let api: Router<Arc<AppState>> = Router::new()
        .route("/health", get(routes::health::health))
        .route("/whoami", get(routes::whoami::whoami))
        .route("/sources/home", get(routes::timeline::home))
        .route("/sources/user/{handle}", get(routes::timeline::user))
        .route("/sources/search", get(routes::timeline::search))
        .route("/sources/mentions", get(routes::timeline::mentions))
        .route("/sources/bookmarks", get(routes::timeline::bookmarks))
        .route(
            "/sources/notifications",
            get(routes::timeline::notifications),
        )
        .route("/feed/status", get(routes::feed::status))
        .route("/tweet/{id}", get(routes::tweet::single))
        .route("/thread/{id}", get(routes::tweet::thread))
        .route("/profile/{handle}", get(routes::profile::profile))
        .route("/likers/{tweet_id}", get(routes::profile::likers))
        .route("/engage/{tweet_id}/like", post(routes::engage::like))
        .route("/engage/{tweet_id}/unlike", post(routes::engage::unlike))
        .route("/compose", post(routes::compose::compose))
        .route("/reply/{tweet_id}", post(routes::compose::reply))
        .route(
            "/seen",
            get(routes::seen::list)
                .post(routes::seen::mark)
                .delete(routes::seen::clear),
        )
        .route("/seen/{id}", get(routes::seen::check))
        .route(
            "/session",
            get(routes::session::get).patch(routes::session::patch),
        )
        .route(
            "/config/filter",
            get(routes::config::get_filter).patch(routes::config::patch_filter),
        )
        .route("/media/{tweet_id}/{index}", get(routes::media::proxy))
        .route("/sse/filter", get(sse::filter_stream))
        .route("/sse/ask", get(sse::ask_stream))
        .route("/sse/brief", get(sse::brief_stream))
        .route("/sse/translate", get(sse::translate_stream));

    Router::new()
        .nest("/api", api)
        .fallback(fallback)
        .layer(CompressionLayer::new())
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
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
