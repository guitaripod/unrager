use crate::auth::chromium;
use crate::config;
use crate::error::Result;
use crate::gql::{GqlClient, QueryIdStore};

pub async fn build_gql_client() -> Result<GqlClient> {
    let session = chromium::load_session().await?;
    let cache_path = config::cache_dir()?.join("query-ids.json");
    let store = QueryIdStore::with_fallbacks_and_cache(&cache_path);
    GqlClient::new(session, store, cache_path)
}
