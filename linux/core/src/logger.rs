//! File-based logging, day one — the Linux analog of
//! `UnragerKit/Support/AppLogger.swift`. Fans `tracing` output to stderr and to
//! an append-only, size-rotated file at `~/.cache/unrager-gtk/unrager.log`
//! (2 MB current + one `.previous.log` backup) so diagnostics survive without a
//! debugger attached. Categories map to `tracing` targets
//! (`api`, `serve`, `media`, `timeline`, `poller`, `ui`, …).

use directories::ProjectDirs;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::prelude::*;

const MAX_BYTES: u64 = 2 * 1024 * 1024;
static INITIALIZED: AtomicBool = AtomicBool::new(false);

pub fn cache_dir() -> Option<PathBuf> {
    ProjectDirs::from("ml", "rawdog", "unrager-gtk").map(|d| d.cache_dir().to_path_buf())
}

pub fn log_file_path() -> Option<PathBuf> {
    cache_dir().map(|d| d.join("unrager.log"))
}

fn previous_path() -> Option<PathBuf> {
    cache_dir().map(|d| d.join("unrager.previous.log"))
}

/// Installs the global subscriber once. Subsequent calls are no-ops. Safe to
/// call from `main` before any GTK work.
pub fn init() {
    if INITIALIZED.swap(true, Ordering::SeqCst) {
        return;
    }

    let stderr_filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let stderr_layer = tracing_subscriber::fmt::layer()
        .with_writer(io::stderr)
        .with_target(true)
        .with_filter(stderr_filter);

    let file_layer = FileWriter::open().map(|writer| {
        tracing_subscriber::fmt::layer()
            .with_ansi(false)
            .with_target(true)
            .with_writer(writer)
            .with_filter(EnvFilter::new("info"))
    });

    let _ = tracing_subscriber::registry()
        .with(stderr_layer)
        .with(file_layer)
        .try_init();
}

struct Rotating {
    current: PathBuf,
    previous: PathBuf,
    file: Option<File>,
    written: u64,
}

impl Rotating {
    fn write_line(&mut self, buf: &[u8]) -> io::Result<()> {
        if self.written + buf.len() as u64 > MAX_BYTES && self.written > 0 {
            self.rotate()?;
        }
        if self.file.is_none() {
            self.file = Some(open_append(&self.current)?);
        }
        if let Some(file) = self.file.as_mut() {
            file.write_all(buf)?;
            self.written += buf.len() as u64;
        }
        Ok(())
    }

    fn rotate(&mut self) -> io::Result<()> {
        self.file = None;
        let _ = std::fs::remove_file(&self.previous);
        let _ = std::fs::rename(&self.current, &self.previous);
        self.written = 0;
        Ok(())
    }
}

#[derive(Clone)]
struct FileWriter {
    inner: Arc<Mutex<Rotating>>,
}

impl FileWriter {
    fn open() -> Option<Self> {
        let current = log_file_path()?;
        let previous = previous_path()?;
        if let Some(dir) = current.parent() {
            std::fs::create_dir_all(dir).ok()?;
        }
        let written = std::fs::metadata(&current).map(|m| m.len()).unwrap_or(0);
        Some(Self {
            inner: Arc::new(Mutex::new(Rotating {
                current,
                previous,
                file: None,
                written,
            })),
        })
    }
}

impl Write for &FileWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if let Ok(mut guard) = self.inner.lock() {
            guard.write_line(buf)?;
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        if let Ok(mut guard) = self.inner.lock()
            && let Some(file) = guard.file.as_mut()
        {
            file.flush()?;
        }
        Ok(())
    }
}

impl<'a> MakeWriter<'a> for FileWriter {
    type Writer = &'a FileWriter;

    fn make_writer(&'a self) -> Self::Writer {
        self
    }
}

fn open_append(path: &PathBuf) -> io::Result<File> {
    OpenOptions::new().create(true).append(true).open(path)
}
