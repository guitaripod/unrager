use axum::Json;
use serde_json::json;

pub async fn health() -> Json<serde_json::Value> {
    Json(json!({
        "ok": true,
        "name": "unrager",
        "version": env!("CARGO_PKG_VERSION"),
        "build": build_info(),
    }))
}

fn build_info() -> serde_json::Value {
    json!({
        "features": {
            "tui": cfg!(feature = "tui"),
            "server": cfg!(feature = "server"),
        },
        "profile": if cfg!(debug_assertions) { "debug" } else { "release" },
    })
}
