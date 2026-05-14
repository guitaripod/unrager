use crate::gql::GqlClient;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::model::AboutProfile;
use crate::parse::about;
use std::sync::Arc;
use tokio::sync::Semaphore;

/// Outcome of an `AboutAccountQuery` round-trip.
///
/// `Ok(Some(_))` — X returned a profile with usable fields.
/// `Ok(None)` — X returned a result but no `about_profile` block (user
///   hasn't set anything). Cache this so we don't refetch every page.
/// `Err(())` — transport, rate-limit, or parse failure. **Don't** cache:
///   we'd otherwise mistake a 429 for "this user has no location" and
///   hide their flag for the entire negative-TTL window.
pub type FetchOutcome = std::result::Result<Option<AboutProfile>, ()>;

#[derive(Clone)]
pub struct AboutFetcher {
    client: Arc<GqlClient>,
    sem: Arc<Semaphore>,
}

impl AboutFetcher {
    pub fn new(client: Arc<GqlClient>) -> Self {
        Self {
            client,
            sem: Arc::new(Semaphore::new(1)),
        }
    }

    pub fn spawn(&self, rest_id: String, screen_name: String, tx: crate::tui::event::EventTx) {
        let client = self.client.clone();
        let sem = self.sem.clone();
        tokio::spawn(async move {
            let _permit = match sem.acquire().await {
                Ok(p) => p,
                Err(_) => return,
            };
            let result = fetch_one(&client, &screen_name).await;
            let _ = tx.send(crate::tui::event::Event::AboutProfileResolved { rest_id, result });
        });
    }
}

async fn fetch_one(client: &GqlClient, screen_name: &str) -> FetchOutcome {
    let response = match client
        .get(
            Operation::AboutAccountQuery,
            &endpoints::about_account_variables(screen_name),
            &endpoints::about_account_features(),
        )
        .await
    {
        Ok(v) => v,
        Err(e) => {
            tracing::debug!("AboutAccountQuery failed for {screen_name}: {e}");
            return Err(());
        }
    };
    match about::parse(&response) {
        Ok(p) if has_any_about_data(&p) => Ok(Some(p)),
        Ok(_) => Ok(None),
        Err(e) => {
            tracing::debug!("AboutAccountQuery parse failed for {screen_name}: {e}");
            Err(())
        }
    }
}

fn has_any_about_data(p: &AboutProfile) -> bool {
    p.account_based_in.is_some()
        || p.source.is_some()
        || p.affiliate_username.is_some()
        || p.verified_since.is_some()
        || p.username_changes.is_some_and(|n| n > 0)
}
