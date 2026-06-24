//! Local `unrager serve` supervisor.
//!
//! The GTK client is a serve-client, like the iOS/macOS apps — but on the
//! user's own Linux box it can manage the server for them. On launch it:
//!
//! 1. uses an explicit non-loopback server URL as-is (Tailscale), or
//! 2. reuses an already-running local server (e.g. one a TUI started), or
//! 3. locates the `unrager` binary, picks a free loopback port, spawns
//!    `unrager serve --bind 127.0.0.1:<port>`, and health-polls it.
//!
//! The spawned child is killed on drop / explicit shutdown.

use crate::models::ServerHealth;
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};
use url::Url;

const DEFAULT_PORT: u16 = 7777;
const HEALTH_DEADLINE: Duration = Duration::from_secs(10);
const HEALTH_POLL: Duration = Duration::from_millis(200);

#[derive(Debug, thiserror::Error)]
pub enum ServeError {
    #[error(
        "the `unrager` binary was not found. Install it with `cargo install --path .` or set UNRAGER_BIN."
    )]
    BinaryNotFound,
    #[error("failed to spawn `unrager serve`: {0}")]
    Spawn(String),
    #[error("`unrager serve` did not become healthy in time.{0}")]
    HealthTimeout(String),
    #[error("could not allocate a local port: {0}")]
    Port(String),
}

/// How the client connected to a server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServeOutcome {
    /// An explicit, non-loopback server (e.g. Tailscale) — not managed by us.
    Remote(Url),
    /// An already-running local server was reused.
    Reused(Url),
    /// A fresh local server was spawned by us.
    Spawned(Url),
}

impl ServeOutcome {
    pub fn base_url(&self) -> &Url {
        match self {
            Self::Remote(u) | Self::Reused(u) | Self::Spawned(u) => u,
        }
    }
}

#[derive(Debug)]
pub struct ServeManager {
    child: Option<Child>,
    outcome: ServeOutcome,
}

impl ServeManager {
    /// Connects to (and if needed spawns) a server. `configured` is the user's
    /// Settings server URL, if any.
    pub async fn start(configured: Option<Url>) -> Result<Self, ServeError> {
        if let Some(url) = &configured
            && !is_loopback(url)
        {
            tracing::info!(target: "serve", "using remote server {url}");
            return Ok(Self {
                child: None,
                outcome: ServeOutcome::Remote(url.clone()),
            });
        }

        let default_local =
            Url::parse(&format!("http://127.0.0.1:{DEFAULT_PORT}")).expect("valid default url");
        let probe = configured
            .clone()
            .filter(is_loopback)
            .unwrap_or_else(|| default_local.clone());

        if health_ok(&probe).await {
            tracing::info!(target: "serve", "reusing running server {probe}");
            return Ok(Self {
                child: None,
                outcome: ServeOutcome::Reused(probe),
            });
        }
        if probe != default_local && health_ok(&default_local).await {
            tracing::info!(target: "serve", "reusing running server {default_local}");
            return Ok(Self {
                child: None,
                outcome: ServeOutcome::Reused(default_local),
            });
        }

        Self::spawn().await
    }

    async fn spawn() -> Result<Self, ServeError> {
        let binary = locate_binary().ok_or(ServeError::BinaryNotFound)?;
        let port = free_loopback_port().map_err(|e| ServeError::Port(e.to_string()))?;
        let bind = format!("127.0.0.1:{port}");
        tracing::info!(target: "serve", "spawning {} serve --bind {bind}", binary.display());

        let mut child = Command::new(&binary)
            .arg("serve")
            .arg("--bind")
            .arg(&bind)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| ServeError::Spawn(e.to_string()))?;

        let base = Url::parse(&format!("http://{bind}")).expect("valid spawned url");
        if wait_healthy(&base).await {
            tracing::info!(target: "serve", "server healthy at {base}");
            return Ok(Self {
                child: Some(child),
                outcome: ServeOutcome::Spawned(base),
            });
        }

        let tail = capture_stderr_tail(&mut child).await;
        let _ = child.kill().await;
        tracing::error!(target: "serve", "server failed to become healthy: {tail}");
        Err(ServeError::HealthTimeout(if tail.is_empty() {
            String::new()
        } else {
            format!(" Last output:\n{tail}")
        }))
    }

    pub fn base_url(&self) -> Url {
        self.outcome.base_url().clone()
    }

    pub fn outcome(&self) -> &ServeOutcome {
        &self.outcome
    }

    pub fn is_spawned(&self) -> bool {
        matches!(self.outcome, ServeOutcome::Spawned(_))
    }

    /// Kills the spawned child (if any). Idempotent.
    pub async fn shutdown(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill().await;
        }
        self.child = None;
    }
}

impl Drop for ServeManager {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.start_kill();
        }
    }
}

fn is_loopback(url: &Url) -> bool {
    matches!(
        url.host_str(),
        Some("127.0.0.1") | Some("localhost") | Some("::1")
    )
}

fn health_url(base: &Url) -> Option<Url> {
    base.join("api/health").ok()
}

async fn health_ok(base: &Url) -> bool {
    let Some(url) = health_url(base) else {
        return false;
    };
    let Ok(client) = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
    else {
        return false;
    };
    match client.get(url).send().await {
        Ok(resp) if resp.status().is_success() => {
            matches!(resp.json::<ServerHealth>().await, Ok(h) if h.ok)
        }
        _ => false,
    }
}

async fn wait_healthy(base: &Url) -> bool {
    let start = tokio::time::Instant::now();
    loop {
        if health_ok(base).await {
            return true;
        }
        if start.elapsed() >= HEALTH_DEADLINE {
            return false;
        }
        tokio::time::sleep(HEALTH_POLL).await;
    }
}

fn free_loopback_port() -> std::io::Result<u16> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    Ok(listener.local_addr()?.port())
}

/// Locates the `unrager` binary: `UNRAGER_BIN` env, then `~/.cargo/bin`, then
/// `$PATH`, then a sibling of the running executable.
fn locate_binary() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("UNRAGER_BIN") {
        let path = PathBuf::from(explicit);
        if path.is_file() {
            return Some(path);
        }
    }

    if let Some(home) = directories::BaseDirs::new() {
        let cargo_bin = home.home_dir().join(".cargo/bin/unrager");
        if cargo_bin.is_file() {
            return Some(cargo_bin);
        }
    }

    if let Ok(path_var) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let candidate = dir.join("unrager");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }

    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        let sibling = dir.join("unrager");
        if sibling.is_file() {
            return Some(sibling);
        }
    }

    None
}

async fn capture_stderr_tail(child: &mut Child) -> String {
    let Some(mut stderr) = child.stderr.take() else {
        return String::new();
    };
    let mut buf = Vec::new();
    let _ = tokio::time::timeout(Duration::from_millis(500), stderr.read_to_end(&mut buf)).await;
    let text = String::from_utf8_lossy(&buf);
    text.lines()
        .rev()
        .take(8)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn classifies_loopback_hosts() {
        assert!(is_loopback(&Url::parse("http://127.0.0.1:7777").unwrap()));
        assert!(is_loopback(&Url::parse("http://localhost:7777").unwrap()));
        assert!(!is_loopback(
            &Url::parse("http://example.com:7777").unwrap()
        ));
        assert!(!is_loopback(&Url::parse("http://100.64.0.1:7777").unwrap()));
    }

    #[test]
    fn allocates_a_free_loopback_port() {
        let port = free_loopback_port().unwrap();
        assert!(port > 0);
        TcpListener::bind(("127.0.0.1", port)).unwrap();
    }

    #[tokio::test]
    async fn remote_url_is_used_without_spawning() {
        let url = Url::parse("http://example.com:7777").unwrap();
        let mgr = ServeManager::start(Some(url.clone())).await.unwrap();
        assert_eq!(mgr.outcome(), &ServeOutcome::Remote(url));
        assert!(!mgr.is_spawned());
    }

    #[tokio::test]
    async fn reuses_a_healthy_loopback_server() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/health"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "ok": true, "name": "unrager", "version": "0.0.0"
            })))
            .mount(&server)
            .await;

        let url = Url::parse(&server.uri()).unwrap();
        let mgr = ServeManager::start(Some(url.clone())).await.unwrap();
        match mgr.outcome() {
            ServeOutcome::Reused(u) => assert_eq!(u.host_str(), url.host_str()),
            other => panic!("expected Reused, got {other:?}"),
        }
        assert!(!mgr.is_spawned());
    }
}
