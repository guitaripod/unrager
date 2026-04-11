use crate::config;
use crate::error::{Error, Result};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Duration, Utc};
use rand::Rng;
use rand::distr::Alphanumeric;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::time::Duration as StdDuration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::time::timeout;

pub const CLIENT_ID: &str = "LS1paXFQbTFyNUxmZnVua2lFVTY6MTpjaQ";
const REDIRECT_URI: &str = "http://127.0.0.1:8765/callback";
const CALLBACK_PORT: u16 = 8765;
const AUTHORIZE_URL: &str = "https://x.com/i/oauth2/authorize";
const TOKEN_URL: &str = "https://api.x.com/2/oauth2/token";
const SCOPES: &str = "tweet.read tweet.write users.read media.write offline.access";
const CALLBACK_TIMEOUT: StdDuration = StdDuration::from_secs(300);
const REFRESH_MARGIN: Duration = Duration::seconds(60);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tokens {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at: DateTime<Utc>,
    pub scope: Option<String>,
}

impl Tokens {
    pub fn is_expired(&self) -> bool {
        Utc::now() + REFRESH_MARGIN >= self.expires_at
    }
}

pub async fn load_or_authorize() -> Result<Tokens> {
    let path = tokens_path()?;
    match load(&path) {
        Ok(Some(tokens)) if !tokens.is_expired() => Ok(tokens),
        Ok(Some(tokens)) => {
            if let Some(refresh) = tokens.refresh_token.as_deref() {
                tracing::debug!("access token expired, refreshing");
                match refresh_tokens(refresh).await {
                    Ok(fresh) => {
                        save(&path, &fresh)?;
                        return Ok(fresh);
                    }
                    Err(e) => {
                        tracing::warn!("refresh failed, falling back to full authorize: {e}");
                    }
                }
            }
            let fresh = run_pkce_flow().await?;
            save(&path, &fresh)?;
            Ok(fresh)
        }
        Ok(None) => {
            tracing::debug!("no token cache, running full PKCE flow");
            let fresh = run_pkce_flow().await?;
            save(&path, &fresh)?;
            Ok(fresh)
        }
        Err(e) => {
            tracing::warn!("token cache unreadable, running full PKCE flow: {e}");
            let fresh = run_pkce_flow().await?;
            save(&path, &fresh)?;
            Ok(fresh)
        }
    }
}

pub fn tokens_path() -> Result<PathBuf> {
    Ok(config::config_dir()?.join("tokens.json"))
}

fn load(path: &std::path::Path) -> Result<Option<Tokens>> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

fn save(path: &std::path::Path, tokens: &Tokens) -> Result<()> {
    use std::io::Write;

    let parent = path.parent().ok_or_else(|| {
        Error::Config(format!(
            "tokens path has no parent directory: {}",
            path.display()
        ))
    })?;
    std::fs::create_dir_all(parent)?;

    let json = serde_json::to_vec_pretty(tokens)?;

    let tmp_path = path.with_extension("json.tmp");
    {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp_path)?;
        file.write_all(&json)?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp_path, path)?;
    Ok(())
}

async fn run_pkce_flow() -> Result<Tokens> {
    let verifier = random_verifier();
    let challenge = code_challenge(&verifier);
    let state: String = rand::rng()
        .sample_iter(&Alphanumeric)
        .take(32)
        .map(char::from)
        .collect();

    let authorize_url = format!(
        "{AUTHORIZE_URL}?response_type=code&client_id={client}\
         &redirect_uri={redirect}&scope={scope}&state={state}\
         &code_challenge={challenge}&code_challenge_method=S256",
        client = urlencoding::encode(CLIENT_ID),
        redirect = urlencoding::encode(REDIRECT_URI),
        scope = urlencoding::encode(SCOPES),
    );

    eprintln!("Opening browser for authorization...");
    eprintln!("If nothing opens, visit this URL manually:");
    eprintln!("  {authorize_url}");
    eprintln!();
    let _ = std::process::Command::new("xdg-open")
        .arg(&authorize_url)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();

    let code = wait_for_callback(&state).await?;
    tracing::debug!("received oauth code, exchanging for tokens");
    exchange_code(&code, &verifier).await
}

fn random_verifier() -> String {
    let mut buf = [0u8; 32];
    rand::rng().fill(&mut buf);
    URL_SAFE_NO_PAD.encode(buf)
}

fn code_challenge(verifier: &str) -> String {
    let hash = Sha256::digest(verifier.as_bytes());
    URL_SAFE_NO_PAD.encode(hash)
}

async fn wait_for_callback(expected_state: &str) -> Result<String> {
    let listener = TcpListener::bind(("127.0.0.1", CALLBACK_PORT))
        .await
        .map_err(|e| {
            Error::Config(format!(
                "failed to bind callback listener on 127.0.0.1:{CALLBACK_PORT}: {e}"
            ))
        })?;

    let accept = async {
        loop {
            let (mut stream, _) = listener.accept().await?;
            let mut buf = vec![0u8; 8192];
            let n = stream.read(&mut buf).await?;
            let request = String::from_utf8_lossy(&buf[..n]);
            let Some(first_line) = request.lines().next() else {
                continue;
            };

            let response_body = match handle_callback_line(first_line, expected_state) {
                Ok(code) => {
                    let html = success_html();
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\
                         Content-Length: {}\r\nConnection: close\r\n\r\n{html}",
                        html.len()
                    );
                    let _ = stream.write_all(response.as_bytes()).await;
                    let _ = stream.shutdown().await;
                    return Ok::<String, Error>(code);
                }
                Err(e) => {
                    let html = error_html(&e.to_string());
                    format!(
                        "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\n\
                         Content-Length: {}\r\nConnection: close\r\n\r\n{html}",
                        html.len()
                    )
                }
            };
            let _ = stream.write_all(response_body.as_bytes()).await;
            let _ = stream.shutdown().await;
        }
    };

    timeout(CALLBACK_TIMEOUT, accept)
        .await
        .map_err(|_| Error::Config("oauth callback timed out after 5 minutes".into()))?
}

fn handle_callback_line(line: &str, expected_state: &str) -> Result<String> {
    let mut parts = line.split_whitespace();
    let _method = parts
        .next()
        .ok_or_else(|| Error::Config("empty request line".into()))?;
    let target = parts
        .next()
        .ok_or_else(|| Error::Config("missing request target".into()))?;

    let Some(query) = target.split_once('?').map(|(_, q)| q) else {
        return Err(Error::Config(
            "callback did not include query parameters".into(),
        ));
    };

    let mut code = None;
    let mut state = None;
    let mut error = None;
    for pair in query.split('&') {
        let Some((k, v)) = pair.split_once('=') else {
            continue;
        };
        let decoded = urlencoding::decode(v)
            .map(|c| c.into_owned())
            .unwrap_or_default();
        match k {
            "code" => code = Some(decoded),
            "state" => state = Some(decoded),
            "error" | "error_description" => error = Some(decoded),
            _ => {}
        }
    }

    if let Some(e) = error {
        return Err(Error::Config(format!("authorization error: {e}")));
    }
    let code = code.ok_or_else(|| Error::Config("no code in callback".into()))?;
    let state = state.ok_or_else(|| Error::Config("no state in callback".into()))?;
    if state != expected_state {
        return Err(Error::Config(
            "csrf state mismatch in oauth callback".into(),
        ));
    }
    Ok(code)
}

async fn exchange_code(code: &str, verifier: &str) -> Result<Tokens> {
    let http = reqwest::Client::new();
    let params = [
        ("grant_type", "authorization_code"),
        ("code", code),
        ("redirect_uri", REDIRECT_URI),
        ("client_id", CLIENT_ID),
        ("code_verifier", verifier),
    ];
    let res = http.post(TOKEN_URL).form(&params).send().await?;
    parse_token_response(res).await
}

async fn refresh_tokens(refresh_token: &str) -> Result<Tokens> {
    let http = reqwest::Client::new();
    let params = [
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
        ("client_id", CLIENT_ID),
    ];
    let res = http.post(TOKEN_URL).form(&params).send().await?;
    parse_token_response(res).await
}

async fn parse_token_response(res: reqwest::Response) -> Result<Tokens> {
    let status = res.status();
    let body = res.text().await?;
    if !status.is_success() {
        return Err(Error::GraphqlStatus {
            status: status.as_u16(),
            body,
        });
    }

    #[derive(Debug, Deserialize)]
    struct Raw {
        access_token: String,
        refresh_token: Option<String>,
        expires_in: i64,
        scope: Option<String>,
    }

    let raw: Raw = serde_json::from_str(&body)?;
    Ok(Tokens {
        access_token: raw.access_token,
        refresh_token: raw.refresh_token,
        expires_at: Utc::now() + Duration::seconds(raw.expires_in),
        scope: raw.scope,
    })
}

fn success_html() -> String {
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>unrager authorized</title>\
     <style>body{font-family:-apple-system,system-ui,sans-serif;background:#0f1419;color:#e7e9ea;\
     display:flex;align-items:center;justify-content:center;height:100vh;margin:0}\
     .card{max-width:480px;padding:2rem;text-align:center}h1{margin:0 0 .5rem}\
     p{opacity:.7;margin:0}</style></head><body><div class=\"card\">\
     <h1>unrager authorized ✓</h1><p>You can close this tab and return to the terminal.</p>\
     </div></body></html>"
        .to_string()
}

fn error_html(msg: &str) -> String {
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>unrager authorization failed</title>\
         <style>body{{font-family:-apple-system,system-ui,sans-serif;background:#0f1419;color:#e7e9ea;\
         display:flex;align-items:center;justify-content:center;height:100vh;margin:0}}\
         .card{{max-width:560px;padding:2rem;text-align:center}}h1{{margin:0 0 .5rem;color:#f4212e}}\
         code{{display:block;margin-top:1rem;padding:1rem;background:#16181c;border-radius:.5rem;\
         text-align:left;word-break:break-word}}</style></head><body><div class=\"card\">\
         <h1>Authorization failed</h1><code>{}</code></div></body></html>",
        html_escape(msg)
    )
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_matches_rfc7636_test_vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
        assert_eq!(code_challenge(verifier), expected);
    }

    #[test]
    fn verifier_is_43_chars_no_padding() {
        let v = random_verifier();
        assert_eq!(v.len(), 43);
        assert!(!v.contains('='));
        assert!(!v.contains('+'));
        assert!(!v.contains('/'));
    }

    #[test]
    fn tokens_is_expired_respects_margin() {
        let t = Tokens {
            access_token: "a".into(),
            refresh_token: None,
            expires_at: Utc::now() + Duration::seconds(30),
            scope: None,
        };
        assert!(t.is_expired());

        let t2 = Tokens {
            access_token: "a".into(),
            refresh_token: None,
            expires_at: Utc::now() + Duration::seconds(600),
            scope: None,
        };
        assert!(!t2.is_expired());
    }
}
