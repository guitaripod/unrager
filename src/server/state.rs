use crate::auth::chromium;
use crate::config;
use crate::error::Result;
use crate::gql::{GqlClient, QueryIdStore};
use crate::tui::filter::{Classifier, FilterCache, FilterConfig};
use crate::tui::seen::SeenStore;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use unrager_model::SessionState;

pub struct AppState {
    pub gql: Arc<GqlClient>,
    pub filter_config: Mutex<FilterConfig>,
    pub filter_cache: Mutex<FilterCache>,
    pub classifier: Mutex<Classifier>,
    pub seen: Mutex<SeenStore>,
    pub session: Mutex<SessionState>,
    pub lock_path: PathBuf,
    pub session_path: PathBuf,
    pub filter_toml_path: PathBuf,
    pub config_dir: PathBuf,
}

impl AppState {
    pub async fn build() -> Result<Self> {
        let session = chromium::load_session().await?;
        let config_dir = config::config_dir()?;
        let cache_dir = config::cache_dir()?;
        let app_config = config::AppConfig::load(&config_dir);
        let query_cache = cache_dir.join("query-ids.json");
        let mut store = QueryIdStore::with_fallbacks_and_cache(&query_cache);
        store.apply_config_overrides(&app_config.query_ids);
        let gql = Arc::new(GqlClient::new(session, store, query_cache)?);

        let filter_toml = config_dir.join("filter.toml");
        let filter_config = FilterConfig::load_or_init(&filter_toml)?;
        let filter_db = cache_dir.join("filter.db");
        let filter_cache = FilterCache::open(&filter_db, filter_config.rubric_hash())?;
        let mut classifier = Classifier::new(&filter_config);
        let _ = classifier.init().await;

        let seen_db = cache_dir.join("seen.db");
        let seen = SeenStore::open(&seen_db)?;

        let session_path = config_dir.join("server-session.json");
        let state: SessionState = load_session_state(&session_path).unwrap_or_default();

        Ok(Self {
            gql,
            filter_config: Mutex::new(filter_config),
            filter_cache: Mutex::new(filter_cache),
            classifier: Mutex::new(classifier),
            seen: Mutex::new(seen),
            session: Mutex::new(state),
            lock_path: cache_dir.join("server.lock"),
            session_path,
            filter_toml_path: filter_toml,
            config_dir,
        })
    }
}

fn load_session_state(path: &std::path::Path) -> Option<SessionState> {
    let txt = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&txt).ok()
}

pub fn save_session_state(path: &std::path::Path, state: &SessionState) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let txt = serde_json::to_string_pretty(state).unwrap_or_else(|_| "{}".into());
    std::fs::write(path, txt)
}
