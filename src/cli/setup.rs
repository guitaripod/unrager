use crate::cli::checks::{self, DEFAULT_BIND, Report, ServerHealth};
use crate::error::{Error, Result};
use clap::Args as ClapArgs;
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(
        long,
        conflicts_with = "filter_only",
        help = "Also serve the iPhone app (reads your X login from your browser); remembered for later runs"
    )]
    pub apps: bool,

    #[arg(
        long,
        help = "Go back to serving only the browser extension after an earlier --apps"
    )]
    pub filter_only: bool,

    #[arg(
        long,
        value_name = "ADDR:PORT",
        help = "Where the background server listens: 127.0.0.1:7777 unless you say otherwise, 0.0.0.0:7777 to reach it over Tailscale; remembered for later runs"
    )]
    pub bind: Option<String>,

    #[arg(
        long,
        help = "Skip the background service and only unpack the browser extension"
    )]
    pub no_service: bool,

    #[arg(
        long,
        help = "Stop and remove the background service and the unpacked extension"
    )]
    pub uninstall: bool,

    /// Used by `unrager update`: restart whatever service is installed and
    /// rewrite an already-unpacked extension, changing nothing else.
    #[arg(long, hide = true)]
    pub refresh: bool,
}

const EXTENSION_FILES: &[(&str, &[u8])] = &[
    (
        "manifest.json",
        include_bytes!("../../browser/extension/manifest.json"),
    ),
    (
        "page-hook.js",
        include_bytes!("../../browser/extension/page-hook.js"),
    ),
    (
        "timeline.js",
        include_bytes!("../../browser/extension/timeline.js"),
    ),
    (
        "content.js",
        include_bytes!("../../browser/extension/content.js"),
    ),
    (
        "content.css",
        include_bytes!("../../browser/extension/content.css"),
    ),
    (
        "background.js",
        include_bytes!("../../browser/extension/background.js"),
    ),
    (
        "popup.html",
        include_bytes!("../../browser/extension/popup.html"),
    ),
    (
        "popup.css",
        include_bytes!("../../browser/extension/popup.css"),
    ),
    (
        "popup.js",
        include_bytes!("../../browser/extension/popup.js"),
    ),
    (
        "icons/16.png",
        include_bytes!("../../browser/extension/icons/16.png"),
    ),
    (
        "icons/32.png",
        include_bytes!("../../browser/extension/icons/32.png"),
    ),
    (
        "icons/48.png",
        include_bytes!("../../browser/extension/icons/48.png"),
    ),
    (
        "icons/128.png",
        include_bytes!("../../browser/extension/icons/128.png"),
    ),
];

pub async fn run(args: Args) -> Result<()> {
    if args.uninstall {
        return uninstall();
    }
    if args.refresh {
        return refresh();
    }
    let saved = Choices::load();
    let choices = Choices::resolve(&args, &saved);
    let bind: SocketAddr = choices
        .bind
        .parse()
        .map_err(|e| Error::Config(format!("invalid --bind {}: {e}", choices.bind)))?;
    let mut report = Report::default();

    println!();
    let remembered =
        !(args.apps || args.filter_only || args.bind.is_some()) && saved != Choices::default();
    checks::llm(&mut report).await;

    if args.no_service {
        println!(
            "· service     skipped — run it yourself: {}",
            serve_command(&choices, bind)
        );
    } else if install_service(&choices, bind, remembered, &mut report).await {
        choices.save();
    }

    let previous = checks::installed_extension_version();
    let dir = checks::extension_dir()?;
    write_extension(&dir)?;
    println!(
        "✓ extension   v{} unpacked at {}",
        checks::bundled_extension_version(),
        dir.display()
    );

    println!();
    match previous.as_deref() {
        Some(v) if v != checks::bundled_extension_version() => {
            println!(
                "Already added it to your browser? Click Reload extension in its popup (or ↻ on"
            );
            println!(
                "its card at chrome://extensions) to move it to v{}. First time? Do this once:",
                checks::bundled_extension_version()
            );
        }
        Some(_) => println!(
            "Already added it to your browser? Then you're done. First time? Do this once:"
        ),
        None => {
            println!("Last step, once: add the extension to Chrome, Brave, Edge, Vivaldi or Arc.")
        }
    }
    println!("  1. open chrome://extensions (it works in all of them)");
    println!("  2. turn on Developer mode");
    println!(
        "  3. click Load unpacked, press {} and paste this folder:",
        FOLDER_PICKER_GOTO
    );
    println!("       {}", dir.display());
    println!();
    println!("Then open x.com: posts matching your rules disappear from For you and Following.");
    if bind.port() != 7777 {
        println!(
            "The extension looks for unrager at http://localhost:7777: set http://localhost:{} under Settings in its popup.",
            bind.port()
        );
    }
    if let Ok(path) = checks::filter_toml_path() {
        println!(
            "Change what gets hidden from the extension's popup, or in {}",
            path.display()
        );
    }
    if report.errors > 0 {
        println!();
        println!("Fix the ✗ lines above, then run `unrager setup` again.");
        std::process::exit(1);
    }
    Ok(())
}

/// How the background server was last set up. Re-running `unrager setup`
/// without flags keeps it, since `--apps` and `--bind` are easy to forget and
/// dropping them would quietly cut the iPhone app off.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Choices {
    apps: bool,
    bind: String,
}

impl Default for Choices {
    fn default() -> Self {
        Self {
            apps: false,
            bind: DEFAULT_BIND.into(),
        }
    }
}

impl Choices {
    fn path() -> Result<PathBuf> {
        Ok(crate::config::data_dir()?.join("setup.json"))
    }

    fn load() -> Self {
        Self::path()
            .ok()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    fn save(&self) {
        let Ok(path) = Self::path() else { return };
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, json);
        }
    }

    fn resolve(args: &Args, saved: &Choices) -> Self {
        Self {
            apps: args.apps || (!args.filter_only && saved.apps),
            bind: args.bind.clone().unwrap_or_else(|| saved.bind.clone()),
        }
    }

    fn flags(&self) -> String {
        let mode = if self.apps { "--apps " } else { "" };
        format!("{mode}--bind {}", self.bind)
    }
}

fn serve_command(choices: &Choices, bind: SocketAddr) -> String {
    let mode = if choices.apps { "" } else { " --filter-only" };
    format!("unrager serve{mode} --bind {bind}")
}

fn serve_args(choices: &Choices, bind: SocketAddr) -> Vec<String> {
    let mut out = vec!["serve".to_string()];
    if !choices.apps {
        out.push("--filter-only".into());
    }
    out.push("--bind".into());
    out.push(bind.to_string());
    out
}

/// Installs and starts the service; true when it's one `unrager setup`
/// manages, whose choices are then worth remembering. `remembered` says the
/// choices came from an earlier run rather than this one's flags.
async fn install_service(
    choices: &Choices,
    bind: SocketAddr,
    remembered: bool,
    report: &mut Report,
) -> bool {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            println!("✗ service     can't find the unrager binary: {e}");
            report.errors += 1;
            return false;
        }
    };
    let managed = match service::install(&exe, &serve_args(choices, bind)) {
        Ok(installed) if installed.managed => {
            if remembered {
                println!(
                    "· settings    kept `{}` from last time (--filter-only or --bind changes it)",
                    choices.flags()
                );
            }
            if !bind.ip().is_loopback() {
                println!(
                    "! service     listening on {bind}: unrager has no login, so keep that to a network you trust (a Tailscale ACL, not public Wi-Fi)"
                );
                report.warnings += 1;
            }
            println!(
                "✓ service     {} runs `{}` in the background",
                installed.description,
                serve_command(choices, bind)
            );
            true
        }
        Ok(installed) => {
            println!(
                "✓ service     restarted {}; you wrote it, so its settings were left alone",
                installed.description
            );
            false
        }
        Err(e) => {
            println!("✗ service     {e}");
            println!(
                "              → run it yourself instead: {}",
                serve_command(choices, bind)
            );
            report.errors += 1;
            return false;
        }
    };
    match wait_for_server(bind).await {
        Some(health) if health.version == env!("CARGO_PKG_VERSION") => {
            println!("✓ server      answering on {bind} ({})", health.mode());
        }
        Some(health) => {
            println!(
                "! server      answering on {bind}, but it's v{} — the service starts a different unrager binary than this one",
                health.version
            );
            report.warnings += 1;
        }
        None => {
            println!("✗ server      didn't answer on {bind} within 20s");
            println!("              → {}", service::LOG_HINT);
            report.errors += 1;
        }
    }
    managed
}

/// Polls `/api/health` until the server answers as this binary's version (a
/// restart can leave the old process answering for a moment), settling for
/// whatever version answered last once the 20 s budget runs out.
async fn wait_for_server(bind: SocketAddr) -> Option<ServerHealth> {
    let host = match bind.ip() {
        ip if ip.is_unspecified() && ip.is_ipv4() => "127.0.0.1".to_string(),
        ip if ip.is_unspecified() => "[::1]".to_string(),
        std::net::IpAddr::V6(ip) => format!("[{ip}]"),
        ip => ip.to_string(),
    };
    let base = format!("http://{host}:{}", bind.port());
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .ok()?;
    let mut last = None;
    for _ in 0..80 {
        if let Some(health) = checks::server_health(&client, &base).await {
            if health.version == env!("CARGO_PKG_VERSION") {
                return Some(health);
            }
            last = Some(health);
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    last
}

/// Writes the extension this binary ships into `dir`, overwriting the files
/// in place so a browser that loaded the folder keeps pointing at it.
fn write_extension(dir: &Path) -> Result<()> {
    for (name, bytes) in EXTENSION_FILES {
        let path = dir.join(name);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&path, bytes)?;
    }
    Ok(())
}

/// Brings an existing setup onto this binary's version without touching how
/// it was configured: the service keeps its own arguments, and the extension
/// is only rewritten if it was unpacked before.
fn refresh() -> Result<()> {
    match service::restart() {
        Ok(Some(description)) => println!(
            "✓ service     restarted {description} on v{}",
            env!("CARGO_PKG_VERSION")
        ),
        Ok(None) => {}
        Err(e) => println!("✗ service     {e}"),
    }
    if let Some(previous) = checks::installed_extension_version() {
        let bundled = checks::bundled_extension_version();
        write_extension(&checks::extension_dir()?)?;
        if previous == bundled {
            println!("✓ extension   v{bundled} rewritten in place");
        } else {
            println!(
                "✓ extension   updated to v{bundled}: click Reload extension in its popup to finish"
            );
        }
    }
    Ok(())
}

fn uninstall() -> Result<()> {
    println!();
    match service::uninstall() {
        Ok(Removal::Removed(description)) => {
            println!("✓ service     stopped and removed {description}")
        }
        Ok(Removal::Foreign(description)) => {
            println!("· service     left {description} in place: you wrote it, not unrager setup")
        }
        Ok(Removal::NotInstalled) => println!("· service     none installed"),
        Err(e) => println!("✗ service     {e}"),
    }
    if let Ok(choices) = Choices::path() {
        let _ = std::fs::remove_file(choices);
    }
    let dir = checks::extension_dir()?;
    if dir.exists() {
        std::fs::remove_dir_all(&dir)?;
        println!("✓ extension   removed {}", dir.display());
        println!();
        println!("Remove the unrager card from your browser's extensions page too.");
    } else {
        println!("· extension   none unpacked");
    }
    Ok(())
}

struct Installed {
    description: &'static str,
    managed: bool,
}

enum Removal {
    Removed(&'static str),
    Foreign(&'static str),
    NotInstalled,
}

/// The folder-picker shortcut for typing a path: the extension lives in a
/// hidden directory, which the picker won't show by default.
#[cfg(target_os = "macos")]
const FOLDER_PICKER_GOTO: &str = "⌘⇧G";
#[cfg(not(target_os = "macos"))]
const FOLDER_PICKER_GOTO: &str = "Ctrl+L";

/// Marks a service file as written by `unrager setup`, so re-running setup
/// may update it while a unit the user wrote by hand is never overwritten.
const MANAGED_MARKER: &str = "Managed by `unrager setup`";

#[cfg(target_os = "linux")]
mod service {
    use super::{Installed, MANAGED_MARKER, Removal};
    use crate::error::{Error, Result};
    use std::path::{Path, PathBuf};
    use std::process::Command;

    const UNIT: &str = "unrager-serve.service";
    const DESCRIPTION: &str = "the unrager-serve systemd user service";
    pub const LOG_HINT: &str = "journalctl --user -u unrager-serve -e";

    fn unit_path() -> Result<PathBuf> {
        let base =
            directories::BaseDirs::new().ok_or_else(|| Error::Config("HOME not set".into()))?;
        Ok(base.config_dir().join("systemd/user").join(UNIT))
    }

    fn systemctl(args: &[&str]) -> Result<()> {
        let out = Command::new("systemctl")
            .arg("--user")
            .args(args)
            .output()
            .map_err(|e| Error::Config(format!("can't run systemctl: {e}")))?;
        if out.status.success() {
            return Ok(());
        }
        Err(Error::Config(format!(
            "systemctl --user {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        )))
    }

    /// systemd splits `ExecStart=` on whitespace and expands `%` specifiers,
    /// so every argument is quoted and `%` doubled.
    fn quote(arg: &str) -> String {
        let escaped = arg
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('%', "%%");
        format!("\"{escaped}\"")
    }

    pub(super) fn unit_contents(exe: &Path, args: &[String]) -> String {
        let mut exec = quote(&exe.display().to_string());
        for arg in args {
            exec.push(' ');
            exec.push_str(&quote(arg));
        }
        format!(
            "# {MANAGED_MARKER}: re-running it updates this file, `unrager setup --uninstall` removes it.\n\
             [Unit]\n\
             Description=unrager rage-filter server\n\
             After=network-online.target\n\
             Wants=network-online.target\n\
             \n\
             [Service]\n\
             Type=simple\n\
             ExecStart={exec}\n\
             Restart=on-failure\n\
             RestartSec=5\n\
             \n\
             [Install]\n\
             WantedBy=default.target\n"
        )
    }

    pub(super) fn install(exe: &Path, args: &[String]) -> Result<Installed> {
        systemctl(&["show-environment"]).map_err(|_| {
            Error::Config(
                "no systemd user session here (WSL or a container?), so nothing can keep the server running".into(),
            )
        })?;
        let path = unit_path()?;
        let desired = unit_contents(exe, args);
        let managed = match std::fs::read_to_string(&path) {
            Ok(existing) if !existing.contains(MANAGED_MARKER) => false,
            Ok(existing) if existing == desired => true,
            _ => {
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                std::fs::write(&path, &desired)?;
                systemctl(&["daemon-reload"])?;
                true
            }
        };
        systemctl(&["enable", UNIT])?;
        systemctl(&["restart", UNIT])?;
        Ok(Installed {
            description: DESCRIPTION,
            managed,
        })
    }

    /// Restarts the unit if it exists and is running; a stopped one stays
    /// stopped.
    pub(super) fn restart() -> Result<Option<&'static str>> {
        if !unit_path()?.exists() {
            return Ok(None);
        }
        systemctl(&["try-restart", UNIT])?;
        Ok(Some(DESCRIPTION))
    }

    pub(super) fn uninstall() -> Result<Removal> {
        let path = unit_path()?;
        match std::fs::read_to_string(&path) {
            Err(_) => Ok(Removal::NotInstalled),
            Ok(existing) if !existing.contains(MANAGED_MARKER) => Ok(Removal::Foreign(DESCRIPTION)),
            Ok(_) => {
                let _ = systemctl(&["disable", "--now", UNIT]);
                std::fs::remove_file(&path)?;
                let _ = systemctl(&["daemon-reload"]);
                Ok(Removal::Removed(DESCRIPTION))
            }
        }
    }
}

#[cfg(target_os = "macos")]
mod service {
    use super::{Installed, MANAGED_MARKER, Removal};
    use crate::error::{Error, Result};
    use std::path::{Path, PathBuf};
    use std::process::Command;

    const LABEL: &str = "com.unrager.serve";
    const DESCRIPTION: &str = "the com.unrager.serve launchd agent";
    pub const LOG_HINT: &str = "tail ~/Library/Logs/unrager-serve.log";

    fn home() -> Result<PathBuf> {
        directories::BaseDirs::new()
            .map(|b| b.home_dir().to_path_buf())
            .ok_or_else(|| Error::Config("HOME not set".into()))
    }

    fn plist_path() -> Result<PathBuf> {
        Ok(home()?
            .join("Library/LaunchAgents")
            .join(format!("{LABEL}.plist")))
    }

    fn domain() -> String {
        format!("gui/{}", unsafe { libc::getuid() })
    }

    fn launchctl(args: &[&str]) -> Result<()> {
        let out = Command::new("launchctl")
            .args(args)
            .output()
            .map_err(|e| Error::Config(format!("can't run launchctl: {e}")))?;
        if out.status.success() {
            return Ok(());
        }
        Err(Error::Config(format!(
            "launchctl {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        )))
    }

    fn xml_escape(s: &str) -> String {
        s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    }

    pub(super) fn plist_contents(exe: &Path, args: &[String], log: &Path) -> String {
        let mut program = format!(
            "    <string>{}</string>\n",
            xml_escape(&exe.display().to_string())
        );
        for arg in args {
            program.push_str(&format!("    <string>{}</string>\n", xml_escape(arg)));
        }
        let log = xml_escape(&log.display().to_string());
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
             <!-- {MANAGED_MARKER}: re-running it updates this file, `unrager setup --uninstall` removes it. -->\n\
             <plist version=\"1.0\">\n\
             <dict>\n\
             \x20 <key>Label</key>\n\
             \x20 <string>{LABEL}</string>\n\
             \x20 <key>ProgramArguments</key>\n\
             \x20 <array>\n\
             {program}\
             \x20 </array>\n\
             \x20 <key>RunAtLoad</key>\n\
             \x20 <true/>\n\
             \x20 <key>KeepAlive</key>\n\
             \x20 <dict>\n\
             \x20   <key>SuccessfulExit</key>\n\
             \x20   <false/>\n\
             \x20 </dict>\n\
             \x20 <key>ProcessType</key>\n\
             \x20 <string>Background</string>\n\
             \x20 <key>StandardOutPath</key>\n\
             \x20 <string>{log}</string>\n\
             \x20 <key>StandardErrorPath</key>\n\
             \x20 <string>{log}</string>\n\
             </dict>\n\
             </plist>\n"
        )
    }

    pub(super) fn install(exe: &Path, args: &[String]) -> Result<Installed> {
        let path = plist_path()?;
        let log = home()?.join("Library/Logs/unrager-serve.log");
        let desired = plist_contents(exe, args, &log);
        let managed = match std::fs::read_to_string(&path) {
            Ok(existing) if !existing.contains(MANAGED_MARKER) => false,
            Ok(existing) if existing == desired => true,
            _ => {
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                std::fs::write(&path, &desired)?;
                true
            }
        };
        let domain = domain();
        let target = format!("{domain}/{LABEL}");
        let _ = launchctl(&["bootout", &target]);
        let _ = launchctl(&["enable", &target]);
        launchctl(&["bootstrap", &domain, &path.display().to_string()])?;
        Ok(Installed {
            description: DESCRIPTION,
            managed,
        })
    }

    /// Restarts the agent if it's loaded; one that isn't stays that way.
    pub(super) fn restart() -> Result<Option<&'static str>> {
        if !plist_path()?.exists() {
            return Ok(None);
        }
        let target = format!("{}/{LABEL}", domain());
        if launchctl(&["print", &target]).is_err() {
            return Ok(None);
        }
        launchctl(&["kickstart", "-k", &target])?;
        Ok(Some(DESCRIPTION))
    }

    pub(super) fn uninstall() -> Result<Removal> {
        let path = plist_path()?;
        match std::fs::read_to_string(&path) {
            Err(_) => Ok(Removal::NotInstalled),
            Ok(existing) if !existing.contains(MANAGED_MARKER) => Ok(Removal::Foreign(DESCRIPTION)),
            Ok(_) => {
                let _ = launchctl(&["bootout", &format!("{}/{LABEL}", domain())]);
                std::fs::remove_file(&path)?;
                Ok(Removal::Removed(DESCRIPTION))
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod service {
    use super::{Installed, Removal};
    use crate::error::{Error, Result};
    use std::path::Path;

    pub const LOG_HINT: &str = "run `unrager serve` in a terminal to see its output";

    pub(super) fn install(_exe: &Path, _args: &[String]) -> Result<Installed> {
        Err(Error::Config(
            "background services are only set up on Linux and macOS".into(),
        ))
    }

    pub(super) fn restart() -> Result<Option<&'static str>> {
        Ok(None)
    }

    pub(super) fn uninstall() -> Result<Removal> {
        Ok(Removal::NotInstalled)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repo_manifest_version_matches_the_crate() {
        let manifest: serde_json::Value =
            serde_json::from_slice(EXTENSION_FILES[0].1).expect("manifest.json parses");
        assert_eq!(
            manifest["version"],
            checks::bundled_extension_version(),
            "bump browser/extension/manifest.json together with Cargo.toml"
        );
    }

    #[test]
    fn every_file_the_manifest_references_is_embedded() {
        let manifest: serde_json::Value = serde_json::from_slice(EXTENSION_FILES[0].1).unwrap();
        let mut referenced: Vec<String> = Vec::new();
        referenced.push(
            manifest["background"]["service_worker"]
                .as_str()
                .unwrap()
                .into(),
        );
        referenced.push(manifest["action"]["default_popup"].as_str().unwrap().into());
        for script in manifest["content_scripts"].as_array().unwrap() {
            for kind in ["js", "css"] {
                for file in script[kind].as_array().into_iter().flatten() {
                    referenced.push(file.as_str().unwrap().into());
                }
            }
        }
        for icons in [&manifest["icons"], &manifest["action"]["default_icon"]] {
            for icon in icons.as_object().unwrap().values() {
                referenced.push(icon.as_str().unwrap().into());
            }
        }
        for name in referenced {
            assert!(
                EXTENSION_FILES.iter().any(|(n, _)| *n == name),
                "{name} is referenced by manifest.json but not embedded"
            );
        }
    }

    #[test]
    fn every_file_the_popup_references_is_embedded() {
        let popup = EXTENSION_FILES
            .iter()
            .find(|(n, _)| *n == "popup.html")
            .map(|(_, b)| String::from_utf8_lossy(b).into_owned())
            .unwrap();
        let refs = regex::Regex::new(r#"(?:src|href)="([^"]+)""#).unwrap();
        for cap in refs.captures_iter(&popup) {
            let name = &cap[1];
            assert!(
                EXTENSION_FILES.iter().any(|(n, _)| *n == name),
                "{name} is referenced by popup.html but not embedded"
            );
        }
    }

    #[test]
    fn every_file_in_the_extension_folder_is_embedded() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("browser/extension");
        let mut stack = vec![root.clone()];
        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    stack.push(path);
                    continue;
                }
                let name = path
                    .strip_prefix(&root)
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/");
                assert!(
                    EXTENSION_FILES.iter().any(|(n, _)| *n == name),
                    "browser/extension/{name} is not in EXTENSION_FILES, so `unrager setup` won't ship it"
                );
            }
        }
    }

    #[test]
    fn write_extension_lays_out_a_loadable_folder() {
        let dir = tempfile::tempdir().unwrap();
        write_extension(dir.path()).unwrap();
        for (name, bytes) in EXTENSION_FILES {
            assert_eq!(&std::fs::read(dir.path().join(name)).unwrap(), bytes);
        }
    }

    fn args(apps: bool, filter_only: bool, bind: Option<&str>) -> Args {
        Args {
            apps,
            filter_only,
            bind: bind.map(str::to_string),
            no_service: false,
            uninstall: false,
            refresh: false,
        }
    }

    #[test]
    fn serve_args_default_to_filter_only() {
        let bind: SocketAddr = DEFAULT_BIND.parse().unwrap();
        let choices = Choices::default();
        assert_eq!(
            serve_args(&choices, bind),
            ["serve", "--filter-only", "--bind", "127.0.0.1:7777"]
        );
        let apps = Choices {
            apps: true,
            ..choices
        };
        assert_eq!(
            serve_args(&apps, bind),
            ["serve", "--bind", "127.0.0.1:7777"]
        );
    }

    #[test]
    fn a_rerun_without_flags_keeps_the_last_choices() {
        let saved = Choices {
            apps: true,
            bind: "0.0.0.0:7777".into(),
        };
        assert_eq!(Choices::resolve(&args(false, false, None), &saved), saved);
        assert_eq!(
            Choices::resolve(&args(false, true, None), &saved),
            Choices {
                apps: false,
                bind: "0.0.0.0:7777".into()
            }
        );
        assert_eq!(
            Choices::resolve(&args(false, false, Some("127.0.0.1:7777")), &saved),
            Choices {
                apps: true,
                bind: "127.0.0.1:7777".into()
            }
        );
        assert_eq!(
            Choices::resolve(&args(true, false, None), &Choices::default()).flags(),
            "--apps --bind 127.0.0.1:7777"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn systemd_unit_quotes_paths_and_escapes_specifiers() {
        let unit = service::unit_contents(
            Path::new("/home/a b/100%/unrager"),
            &["serve".into(), "--filter-only".into()],
        );
        assert!(unit.contains(MANAGED_MARKER));
        assert!(unit.contains(r#"ExecStart="/home/a b/100%%/unrager" "serve" "--filter-only""#));
        assert!(unit.contains("WantedBy=default.target"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn launchd_plist_escapes_xml() {
        let plist = service::plist_contents(
            Path::new("/Users/a&b/unrager"),
            &["serve".into()],
            Path::new("/tmp/log"),
        );
        assert!(plist.contains("<string>/Users/a&amp;b/unrager</string>"));
        assert!(plist.contains(MANAGED_MARKER));
    }
}
