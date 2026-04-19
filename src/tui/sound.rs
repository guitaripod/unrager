//! Opt-in audio loop for Mordor mode. Two user-supplied sources in
//! precedence order:
//! 1. `[sound] source = "..."` in `config.toml` — `ffmpeg` slices the
//!    configured segment into a hash-keyed Opus file under `cache_dir`
//!    (keyed on source mtime + start/end/fade/volume so edits invalidate).
//! 2. A pre-encoded file the user drops at
//!    `config_dir/mordor-sound.{opus,ogg,oga,flac,mp3,wav}` — used raw.
//!
//! If neither is present, `Player::init` returns `None` and Mordor mode is
//! silent. There is no synthesized fallback — users who want audio
//! configure a file, users who don't hear nothing.
//!
//! No Rust audio deps — keeps ALSA out of the build graph and shipped
//! binaries free of `libasound` load-time requirements.
//!
//! Playback strategy, in preference order:
//! * `ffplay -loop 0` or `mpv --loop=inf` — native gapless loop
//! * fallback: `sh -c 'while :; do <paplay|pw-play|afplay|aplay> FILE; done'`
//!   with a ~20 ms gap between iterations (audible as a soft pulse)
//!
//! `start_loop` is idempotent; `stop_loop` kills the child and reaps it.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

pub struct Player {
    backend: Backend,
    audio_path: PathBuf,
    child: Mutex<Option<Child>>,
}

#[derive(Clone, Copy, Debug)]
enum Backend {
    Ffplay,
    Mpv,
    Paplay,
    PwPlay,
    Afplay,
    Aplay,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AudioFormat {
    Wav,
    Opus,
    Ogg,
    Mp3,
    Flac,
}

impl AudioFormat {
    fn from_ext(ext: &str) -> Option<Self> {
        match ext.to_ascii_lowercase().as_str() {
            "wav" => Some(Self::Wav),
            "opus" => Some(Self::Opus),
            "ogg" | "oga" => Some(Self::Ogg),
            "mp3" => Some(Self::Mp3),
            "flac" => Some(Self::Flac),
            _ => None,
        }
    }
}

impl Backend {
    fn binary(self) -> &'static str {
        match self {
            Self::Ffplay => "ffplay",
            Self::Mpv => "mpv",
            Self::Paplay => "paplay",
            Self::PwPlay => "pw-play",
            Self::Afplay => "afplay",
            Self::Aplay => "aplay",
        }
    }

    /// Backends that know how to loop internally get a zero-gap play; the
    /// rest fall back to a shell `while`-loop with ~20ms between iterations.
    fn has_native_loop(self) -> bool {
        matches!(self, Self::Ffplay | Self::Mpv)
    }

    /// Which formats each player actually decodes. `ffplay` and `mpv` use
    /// ffmpeg's full codec stack so they handle everything. The rest are
    /// restricted — `aplay`/`pw-play` only speak WAV; `paplay` uses
    /// libsndfile (WAV + FLAC + OGG, no MP3/Opus); `afplay` uses CoreAudio
    /// (WAV + MP3 + FLAC, no Opus/Ogg on older macOS).
    fn supports(self, fmt: AudioFormat) -> bool {
        match (self, fmt) {
            (Self::Ffplay | Self::Mpv, _) => true,
            (Self::Afplay, AudioFormat::Opus | AudioFormat::Ogg) => false,
            (Self::Afplay, _) => true,
            (Self::Paplay, AudioFormat::Mp3 | AudioFormat::Opus) => false,
            (Self::Paplay, _) => true,
            (Self::PwPlay | Self::Aplay, AudioFormat::Wav) => true,
            (Self::PwPlay | Self::Aplay, _) => false,
        }
    }
}

impl Player {
    /// Probes the environment. Returns `None` unless `UNRAGER_SOUND=1` is
    /// set AND the user has configured an audio source AND a compatible
    /// backend is on `$PATH`. Without a source configured, Mordor mode is
    /// silent — there is no synthesized fallback.
    ///
    /// Source precedence:
    /// 1. `[sound] source = "..."` in `config.toml` — if set and `ffmpeg` is
    ///    on `$PATH`, slice/fade/downmix into a cached Opus file whose name
    ///    is keyed by the config + source mtime (so edits invalidate).
    /// 2. `config_dir/mordor-sound.{opus,ogg,oga,flac,mp3,wav}` — used raw.
    pub fn init(
        cache_dir: &Path,
        config_dir: &Path,
        cfg: &crate::config::SoundConfig,
    ) -> Option<Self> {
        if std::env::var("UNRAGER_SOUND").ok().as_deref() != Some("1") {
            return None;
        }

        let (audio_path, format) =
            resolve_source(cache_dir, config_dir, cfg).or_else(|| user_audio_file(config_dir))?;

        let backend = detect_backend(format)?;

        tracing::info!(
            backend = ?backend,
            native_loop = backend.has_native_loop(),
            path = %audio_path.display(),
            format = ?format,
            "sound enabled"
        );
        Some(Self {
            backend,
            audio_path,
            child: Mutex::new(None),
        })
    }

    pub fn start_loop(&self) {
        let mut guard = self.child.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_some() {
            return;
        }
        let Some(path) = self.audio_path.to_str() else {
            return;
        };
        let child = if self.backend.has_native_loop() {
            spawn_native(self.backend, path)
        } else {
            spawn_shell_loop(self.backend.binary(), path)
        };
        match child {
            Ok(c) => {
                tracing::info!(backend = ?self.backend, pid = c.id(), "mordor loop started");
                *guard = Some(c);
            }
            Err(e) => tracing::warn!(backend = ?self.backend, ?e, "mordor loop spawn failed"),
        }
    }

    pub fn stop_loop(&self) {
        let mut guard = self.child.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut child) = guard.take() {
            let pid = child.id();
            let _ = child.kill();
            let _ = child.wait();
            tracing::info!(pid, "mordor loop stopped");
        }
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        self.stop_loop();
    }
}

fn spawn_native(backend: Backend, wav: &str) -> std::io::Result<Child> {
    let (prog, args): (&str, Vec<&str>) = match backend {
        Backend::Ffplay => (
            "ffplay",
            vec!["-nodisp", "-loop", "0", "-loglevel", "quiet", wav],
        ),
        Backend::Mpv => (
            "mpv",
            vec!["--loop=inf", "--no-video", "--really-quiet", wav],
        ),
        _ => unreachable!("caller gated on has_native_loop"),
    };
    Command::new(prog)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}

fn spawn_shell_loop(binary: &str, wav: &str) -> std::io::Result<Child> {
    let script = format!(
        "while :; do {binary} {wav} >/dev/null 2>&1 || break; done",
        binary = shell_quote(binary),
        wav = shell_quote(wav),
    );
    Command::new("sh")
        .arg("-c")
        .arg(script)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}

fn shell_quote(s: &str) -> String {
    let escaped = s.replace('\'', r"'\''");
    format!("'{escaped}'")
}

fn detect_backend(format: AudioFormat) -> Option<Backend> {
    [
        Backend::Ffplay,
        Backend::Mpv,
        Backend::Paplay,
        Backend::PwPlay,
        Backend::Afplay,
        Backend::Aplay,
    ]
    .into_iter()
    .find(|b| b.supports(format) && binary_on_path(b.binary()))
}

/// Slices/fades/downmixes the configured `source` into a cached Opus loop,
/// keyed by a hash of the config + source mtime so edits invalidate. Returns
/// `None` when `source` is unset, the file doesn't exist, `ffmpeg` isn't on
/// `$PATH`, or any command fails.
fn resolve_source(
    cache_dir: &Path,
    _config_dir: &Path,
    cfg: &crate::config::SoundConfig,
) -> Option<(PathBuf, AudioFormat)> {
    let source = cfg.source.as_ref()?;
    let source_path = Path::new(source);
    if !source_path.is_file() {
        tracing::warn!(path = source, "configured sound.source does not exist");
        return None;
    }
    if !binary_on_path("ffmpeg") {
        tracing::warn!("sound.source is set but ffmpeg is not on $PATH — skipping");
        return None;
    }

    let start_s = cfg
        .start
        .as_deref()
        .map(|s| parse_timestamp(s).unwrap_or(0.0))
        .unwrap_or(0.0);
    let end_s = cfg
        .end
        .as_deref()
        .and_then(parse_timestamp)
        .filter(|&e| e > start_s);
    let duration_s = end_s
        .map(|e| e - start_s)
        .or(cfg.duration)
        .filter(|&d| d > 0.0);
    let fade_s = (cfg.fade_ms as f32) / 1000.0;
    let volume = cfg.volume.clamp(0.0, 1.0);

    let mtime = std::fs::metadata(source_path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let hash = cache_hash(source, mtime, start_s, duration_s, cfg.fade_ms, volume);
    let out_path = cache_dir.join(format!("mordor-user-{hash:016x}.opus"));

    if !out_path.exists() {
        std::fs::create_dir_all(cache_dir).ok()?;
        if !run_ffmpeg(source_path, &out_path, start_s, duration_s, fade_s, volume) {
            return None;
        }
        tracing::info!(
            source = source,
            start = start_s,
            duration = ?duration_s,
            out = %out_path.display(),
            "mordor audio encoded"
        );
    }

    Some((out_path, AudioFormat::Opus))
}

/// Accepts `"SS"`, `"SS.ms"`, `"MM:SS"`, or `"HH:MM:SS"` timestamp forms,
/// each component a non-negative decimal. Returns `None` on parse failure.
fn parse_timestamp(s: &str) -> Option<f32> {
    let s = s.trim();
    let parts: Vec<&str> = s.split(':').collect();
    let nums: Vec<f32> = parts
        .iter()
        .map(|p| p.parse::<f32>().ok())
        .collect::<Option<Vec<_>>>()?;
    if nums.iter().any(|&n| n < 0.0) {
        return None;
    }
    match nums.as_slice() {
        [s] => Some(*s),
        [m, s] => Some(m * 60.0 + s),
        [h, m, s] => Some(h * 3600.0 + m * 60.0 + s),
        _ => None,
    }
}

fn cache_hash(
    source: &str,
    mtime: u64,
    start: f32,
    duration: Option<f32>,
    fade_ms: u32,
    volume: f32,
) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    source.hash(&mut h);
    mtime.hash(&mut h);
    start.to_bits().hash(&mut h);
    duration.map(|d| d.to_bits()).hash(&mut h);
    fade_ms.hash(&mut h);
    volume.to_bits().hash(&mut h);
    h.finish()
}

fn run_ffmpeg(
    source: &Path,
    out: &Path,
    start_s: f32,
    duration_s: Option<f32>,
    fade_s: f32,
    volume: f32,
) -> bool {
    let total = match duration_s {
        Some(d) => d,
        None => match probe_duration(source) {
            Some(d) => (d - start_s).max(0.1),
            None => {
                tracing::warn!("ffprobe failed and no duration configured — skipping encode");
                return false;
            }
        },
    };
    let fade_out_start = (total - fade_s).max(0.0);
    let filter = format!(
        "afade=t=in:st=0:d={fade_s},afade=t=out:st={fade_out_start}:d={fade_s},volume={volume}"
    );

    let mut cmd = Command::new("ffmpeg");
    cmd.args(["-y", "-hide_banner", "-loglevel", "error"])
        .args(["-ss", &format!("{start_s}")])
        .arg("-i")
        .arg(source)
        .args(["-t", &format!("{total}")])
        .args(["-af", &filter])
        .args(["-ac", "1", "-ar", "24000"])
        .args(["-c:a", "libopus", "-b:a", "24k"])
        .arg(out)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());

    match cmd.output() {
        Ok(o) if o.status.success() => true,
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            tracing::warn!(status = ?o.status, stderr = %stderr, "ffmpeg encode failed");
            let _ = std::fs::remove_file(out);
            false
        }
        Err(e) => {
            tracing::warn!(?e, "ffmpeg spawn failed");
            false
        }
    }
}

/// Reads the source's duration (in seconds) via `ffprobe`. Only called when
/// the user hasn't given us a `duration` or `end`.
fn probe_duration(source: &Path) -> Option<f32> {
    let out = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(source)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8(out.stdout).ok()?.trim().parse().ok()
}

fn user_audio_file(config_dir: &Path) -> Option<(PathBuf, AudioFormat)> {
    for ext in ["opus", "ogg", "oga", "flac", "mp3", "wav"] {
        let path = config_dir.join(format!("mordor-sound.{ext}"));
        if path.is_file() {
            let fmt = AudioFormat::from_ext(ext)?;
            return Some((path, fmt));
        }
    }
    None
}

fn binary_on_path(bin: &str) -> bool {
    let Ok(path) = std::env::var("PATH") else {
        return false;
    };
    path.split(':')
        .any(|dir| Path::new(dir).join(bin).is_file())
}

/// Renders the looping ominous phrase as 16-bit mono PCM.
///
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_quote_escapes_single_quotes() {
        assert_eq!(shell_quote("simple"), "'simple'");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
    }

    #[test]
    fn parse_timestamp_accepts_common_forms() {
        assert_eq!(parse_timestamp("55"), Some(55.0));
        assert_eq!(parse_timestamp("55.5"), Some(55.5));
        assert_eq!(parse_timestamp("0:55"), Some(55.0));
        assert_eq!(parse_timestamp("1:40"), Some(100.0));
        assert_eq!(parse_timestamp("1:02:03"), Some(3723.0));
        assert_eq!(parse_timestamp(" 0:55 "), Some(55.0));
    }

    #[test]
    fn parse_timestamp_rejects_garbage() {
        assert_eq!(parse_timestamp(""), None);
        assert_eq!(parse_timestamp("nope"), None);
        assert_eq!(parse_timestamp("-5"), None);
        assert_eq!(parse_timestamp("1:2:3:4"), None);
    }

    #[test]
    fn cache_hash_changes_with_any_param() {
        let base = cache_hash("/a.flac", 100, 0.0, Some(45.0), 50, 0.5);
        assert_ne!(base, cache_hash("/b.flac", 100, 0.0, Some(45.0), 50, 0.5));
        assert_ne!(base, cache_hash("/a.flac", 101, 0.0, Some(45.0), 50, 0.5));
        assert_ne!(base, cache_hash("/a.flac", 100, 1.0, Some(45.0), 50, 0.5));
        assert_ne!(base, cache_hash("/a.flac", 100, 0.0, Some(40.0), 50, 0.5));
        assert_ne!(base, cache_hash("/a.flac", 100, 0.0, Some(45.0), 30, 0.5));
        assert_ne!(base, cache_hash("/a.flac", 100, 0.0, Some(45.0), 50, 0.6));
        assert_eq!(base, cache_hash("/a.flac", 100, 0.0, Some(45.0), 50, 0.5));
    }
}
