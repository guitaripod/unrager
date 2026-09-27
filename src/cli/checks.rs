use crate::config;
use crate::error::Result;
use crate::tui::filter::{
    ChatRequest, DEFAULT_OLLAMA_MODEL, FilterConfig, LlmBackend, LlmConfig, pick_fallback_model,
};
use std::path::PathBuf;
use std::time::Duration;

/// Where `unrager setup` binds the background server, and where every
/// check (and the browser extension's default endpoint) looks for it.
pub const DEFAULT_BIND: &str = "127.0.0.1:7777";

/// Common local defaults for model servers, probed when the configured one
/// is unreachable so the fix can be printed ready to paste.
const LOCAL_MODEL_SERVERS: &[(&str, LlmBackend, &str)] = &[
    ("http://localhost:11434", LlmBackend::Ollama, "Ollama"),
    ("http://localhost:8000", LlmBackend::OpenAi, "vLLM"),
    (
        "http://localhost:8080",
        LlmBackend::OpenAi,
        "llama.cpp / llama-swap",
    ),
    ("http://localhost:1234", LlmBackend::OpenAi, "LM Studio"),
    ("http://localhost:30000", LlmBackend::OpenAi, "SGLang"),
];

#[derive(Default)]
pub struct Report {
    pub errors: usize,
    pub warnings: usize,
}

pub fn filter_toml_path() -> Result<PathBuf> {
    Ok(config::config_dir()?.join("filter.toml"))
}

pub fn load_filter_cfg() -> Result<FilterConfig> {
    FilterConfig::load_or_init(&filter_toml_path()?)
}

/// The extension version this binary ships: the crate version without any
/// pre-release/build suffix, since browsers only accept dotted integers.
pub fn bundled_extension_version() -> &'static str {
    let v = env!("CARGO_PKG_VERSION");
    v.split(['-', '+']).next().unwrap_or(v)
}

pub fn extension_dir() -> Result<PathBuf> {
    Ok(config::data_dir()?.join("browser-extension"))
}

/// The installed extension's version, read from its manifest, if unpacked.
pub fn installed_extension_version() -> Option<String> {
    let manifest = std::fs::read_to_string(extension_dir().ok()?.join("manifest.json")).ok()?;
    let parsed: serde_json::Value = serde_json::from_str(&manifest).ok()?;
    parsed.get("version")?.as_str().map(str::to_string)
}

fn backend_name(backend: LlmBackend) -> &'static str {
    match backend {
        LlmBackend::Ollama => "Ollama",
        LlmBackend::OpenAi => "OpenAI-compatible server",
    }
}

pub async fn llm(report: &mut Report) {
    let path = filter_toml_path()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "filter.toml".into());
    let filter_cfg = match load_filter_cfg() {
        Ok(c) => c,
        Err(e) => {
            println!("✗ llm         {path} unreadable: {e}");
            report.errors += 1;
            return;
        }
    };
    let filter = filter_cfg.llm.for_filter();
    let host = filter.host.trim_end_matches('/');
    let kind = backend_name(filter.backend);

    let models = match filter.list_models().await {
        Ok(m) => m,
        Err(e) => {
            println!("✗ llm         {kind} not reachable at {host} ({e})");
            match filter.backend {
                LlmBackend::Ollama => {
                    println!(
                        "              → install Ollama from https://ollama.com, then: ollama pull {DEFAULT_OLLAMA_MODEL}"
                    );
                }
                LlmBackend::OpenAi => {
                    println!("              → start your model server, or fix `host` in {path}");
                }
            }
            suggest_local_servers(host).await;
            report.errors += 1;
            return;
        }
    };

    let separate = filter.model != filter_cfg.llm.model;
    let filter_role = if separate {
        ModelRole::Filter
    } else {
        ModelRole::Everything
    };
    if check_model(&filter, &models, filter_role, &path, report) {
        if let LlmBackend::OpenAi = filter.backend {
            smoke_test(&filter, report).await;
        }
    }
    if separate {
        check_model(
            &filter_cfg.llm,
            &models,
            ModelRole::AskBriefTranslate,
            &path,
            report,
        );
    }
}

/// What a checked model is used for: a model only ask, brief and translate
/// use is a warning when missing, since the filter works without it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum ModelRole {
    Everything,
    Filter,
    AskBriefTranslate,
}

impl ModelRole {
    fn suffix(self) -> &'static str {
        match self {
            ModelRole::Everything => "",
            ModelRole::Filter => " (filter)",
            ModelRole::AskBriefTranslate => " (ask, brief, translate)",
        }
    }

    fn key(self) -> &'static str {
        match self {
            ModelRole::Filter => "filter_model",
            ModelRole::Everything | ModelRole::AskBriefTranslate => "model",
        }
    }
}

/// Reports whether the server has `llm.model`, returning whether it does.
fn check_model(
    llm: &LlmConfig,
    models: &[String],
    role: ModelRole,
    path: &str,
    report: &mut Report,
) -> bool {
    let host = llm.host.trim_end_matches('/');
    let model = &llm.model;
    let suffix = role.suffix();
    let needed = role != ModelRole::AskBriefTranslate;
    let missing = |report: &mut Report| {
        if needed {
            report.errors += 1;
        } else {
            report.warnings += 1;
        }
    };
    let mark = if needed { "✗" } else { "!" };
    match llm.backend {
        LlmBackend::Ollama => {
            if llm.is_served_by(models) {
                println!("✓ llm         Ollama at {host} · {model}{suffix}");
                return true;
            }
            match pick_fallback_model(models).filter(|_| needed) {
                Some(fallback) => {
                    println!(
                        "! llm         {model} isn't pulled; the filter falls back to {fallback}"
                    );
                    println!("              → ollama pull {model}");
                    report.warnings += 1;
                }
                None => {
                    println!("{mark} llm         Ollama at {host} has no {model}{suffix}");
                    println!("              → ollama pull {model}");
                    if !models.is_empty() {
                        println!(
                            "              → or set `{}` in {path} to one you have: {}",
                            role.key(),
                            models.join(", ")
                        );
                    }
                    missing(report);
                }
            }
            false
        }
        LlmBackend::OpenAi => {
            if !llm.is_served_by(models) {
                println!("{mark} llm         {host} doesn't serve {model:?}{suffix}");
                println!(
                    "              → set `{}` in {path} to one it does: {}",
                    role.key(),
                    models.join(", ")
                );
                missing(report);
                return false;
            }
            println!("✓ llm         OpenAI-compatible server at {host} · {model}{suffix}");
            true
        }
    }
}

/// One real generation: an OpenAI-compatible server can list a model it
/// can't actually run (still loading, broken quantization), which a models
/// listing alone would call healthy.
async fn smoke_test(llm: &LlmConfig, report: &mut Report) {
    println!(
        "              checking it answers (a model that has to load first can take a minute)…"
    );
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(180))
        .build()
        .unwrap_or_default();
    let req = ChatRequest {
        messages: vec![serde_json::json!({
            "role": "user",
            "content": "Say the word banana three times, nothing else."
        })],
        thinking: false,
        temperature: 0.0,
        max_tokens: 16,
    };
    match llm.chat_with_client(req, &client).await {
        Ok(reply) if reply.content.to_ascii_lowercase().contains("banana") => {
            println!("✓ llm         answers coherently");
        }
        Ok(reply) => {
            println!(
                "! llm         answered, but not coherently: {:?}",
                reply.content
            );
            println!(
                "              → check the model server's logs (a broken quantization or template can do this)"
            );
            report.warnings += 1;
        }
        Err(e) => {
            println!("✗ llm         generation failed: {e}");
            report.errors += 1;
        }
    }
}

async fn suggest_local_servers(configured_host: &str) {
    let probes = LOCAL_MODEL_SERVERS
        .iter()
        .filter(|(host, _, _)| *host != configured_host)
        .map(|&(host, backend, name)| async move {
            let probe = LlmConfig {
                backend,
                model: String::new(),
                host: host.to_string(),
                timeout_seconds: 2,
                keep_alive: String::new(),
                api_key: None,
                filter_model: None,
            };
            match probe.list_models_within(Duration::from_millis(800)).await {
                Ok(models) if !models.is_empty() => Some((host, backend, name, models)),
                _ => None,
            }
        });
    let found: Vec<_> = futures::future::join_all(probes)
        .await
        .into_iter()
        .flatten()
        .collect();
    let Some((host, backend, name, models)) = found.first() else {
        return;
    };
    println!("              found {name} running at {host} — to use it, put this in filter.toml:");
    println!("                [llm]");
    println!("                backend = \"{}\"", backend.as_str());
    println!("                host = \"{host}\"");
    println!("                model = \"{}\"", models[0]);
    if models.len() > 1 {
        println!(
            "                # it also serves: {}",
            models[1..].join(", ")
        );
    }
}

/// What `GET /api/health` says about a running `unrager serve`.
pub struct ServerHealth {
    pub version: String,
    pub filter_only: bool,
}

impl ServerHealth {
    pub fn mode(&self) -> &'static str {
        if self.filter_only {
            "filter only"
        } else {
            "filter and iPhone app"
        }
    }
}

/// Asks the server at `base` (e.g. `http://127.0.0.1:7777`) for its health,
/// if one answers there.
pub async fn server_health(client: &reqwest::Client, base: &str) -> Option<ServerHealth> {
    let body: serde_json::Value = client
        .get(format!("{base}/api/health"))
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;
    Some(ServerHealth {
        version: body.get("version")?.as_str()?.to_string(),
        filter_only: body
            .get("filter_only")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
    })
}

pub async fn server(report: &mut Report) {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap_or_default();
    match server_health(&client, &format!("http://{DEFAULT_BIND}")).await {
        Some(health) if health.version == env!("CARGO_PKG_VERSION") => {
            println!(
                "✓ server      answering on {DEFAULT_BIND} ({})",
                health.mode()
            );
        }
        Some(health) => {
            println!(
                "! server      answering on {DEFAULT_BIND}, but it's v{} (this unrager is v{})",
                health.version,
                env!("CARGO_PKG_VERSION")
            );
            println!("              → unrager setup   (restarts it on this version)");
            report.warnings += 1;
        }
        None => {
            println!(
                "✗ server      nothing answering on {DEFAULT_BIND}, so the extension can't work"
            );
            println!("              → unrager setup   (runs it in the background)");
            report.errors += 1;
        }
    }
}

pub fn extension(report: &mut Report) {
    let dir = extension_dir()
        .map(|d| d.display().to_string())
        .unwrap_or_default();
    match installed_extension_version() {
        Some(v) if v == bundled_extension_version() => {
            println!("✓ extension   unpacked at {dir}");
        }
        Some(v) => {
            println!(
                "! extension   {dir} holds v{v} (this unrager ships v{})",
                bundled_extension_version()
            );
            println!(
                "              → unrager setup, then hit ↻ on the unrager card in your browser's extensions page"
            );
            report.warnings += 1;
        }
        None => {
            println!("· extension   not set up — `unrager setup` adds the x.com browser filter");
        }
    }
}
