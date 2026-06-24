# unrager-gtk — native Linux desktop client

A GTK4 / libadwaita desktop client for [unrager](../README.md), the calm
Twitter/X reader. It is the Linux-native peer of the iOS and macOS apps: a
**serve-client** that talks to `unrager serve` over HTTP + SSE and reuses the
byte-exact [`unrager-model`](../crates/unrager-model) wire types.

On launch it manages the server for you — it reuses an already-running local
`unrager serve` (e.g. one a TUI started on `127.0.0.1:7777`), or spawns its own
on a free loopback port and shuts it down on exit. Point it at a remote
(Tailscale) server in Settings to skip spawning.

This is a **separate cargo workspace** from the root crate — it pulls in heavy
GTK system dependencies and is Linux-GUI-only, so it stays out of the root
`--workspace` build/CI. It depends on `unrager-model` by path.

## Layout

- `core/` — `unrager-gtk-core`: headless, GTK-free, fully unit-tested. The typed
  HTTP/SSE `ApiClient`, the `ServeManager` supervisor, `AppSettings` (XDG TOML),
  the file logger (XDG cache, size-rotated), and the `Format` helpers — a Rust
  port of the Swift `UnragerKit` package. `cargo test -p unrager-gtk-core` runs
  with no GTK linkage.
- `app/` — `unrager-gtk`: the relm4 + libadwaita UI (shell, feed, thread,
  profile, search, settings).

## Prerequisites

A logged-in X session in a Chromium-family browser (the server extracts
cookies) and the `unrager` binary installed:

```sh
cargo install --path ..        # puts `unrager` on ~/.cargo/bin
```

### System packages

**Arch:**

```sh
sudo pacman -S gtk4 libadwaita base-devel pkgconf
```

**Debian/Ubuntu:**

```sh
sudo apt-get install libgtk-4-dev libadwaita-1-dev build-essential pkg-config
```

**macOS (compile/iterate only — the real target is Linux):**

```sh
brew install gtk4 libadwaita pkgconf
```

## Build & run

```sh
cd linux
cargo run -p unrager-gtk          # debug
cargo build -p unrager-gtk --release

# headless core tests (no GTK needed):
cargo test -p unrager-gtk-core
```

## Configuration

- `~/.config/unrager-gtk/config.toml` — client settings (server URL, appearance,
  text size, media size, image/seen/filter toggles). Distinct from the TUI's
  config.
- `~/.cache/unrager-gtk/unrager.log` — rolling diagnostics (2 MB + one backup).
- On launch it installs the bundled unrager icon into
  `~/.local/share/icons/hicolor/<size>/apps/ml.rawdog.unrager.png` and a launcher
  at `~/.local/share/applications/ml.rawdog.unrager.desktop`, so the compositor
  shows the app icon (matched to the window's `ml.rawdog.unrager` app id).
  Idempotent — only rewrites when the bytes change.
- `UNRAGER_BIN` — explicit path to the `unrager` binary if it isn't on `$PATH`
  or `~/.cargo/bin`.
- `UNRAGER_DEFAULT_SERVER` — default server URL (e.g. a Tailscale address) for a
  fresh install.

## Status

Feature-complete against the Apple apps within the server's API ceiling:

- For You / Following / Notifications / Search / Mentions / Bookmarks, with
  thread and profile (header + Brief) drilldown.
- Optimistic like, circular `adw::Avatar`s (with initials fallback), inline
  photos shown whole, multi-image grids, video/GIF as a poster + play badge, and
  a media viewer (`gtk::Video` playback where the GTK GStreamer backend is
  present, Left/Right/Escape keys, "Open on X") with paging. Right-click any
  image for a native menu: open, copy/save the image, open/copy the image and
  tweet URLs.
- Loading / empty / error discipline on every data screen — an `adw::Spinner`
  while fetching, an `adw::StatusPage` (with a Try Again button) on failure
  instead of a vanishing toast — and a content-width clamp so feeds stay
  readable on wide windows.
- Compose / reply (copies the draft and opens the X intent, like the Apple apps;
  Post disables until valid, Ctrl+Return submits), and the Ask / Brief /
  Translate streaming LLM sheet.
- Appearance, text size, and media size (Large fills the tweet column at the
  image's true aspect; Compact/Standard show a smaller centered image), the
  rage-filter toggle, a background notifications
  poller with desktop notifications, and keyboard shortcuts (Ctrl+1/2/3/5/6,
  Ctrl+F search, Ctrl+N compose, Ctrl+R refresh, Ctrl+, settings).

Verified on Arch / KDE Wayland. Still to do: a shortcuts help window, inline
(in-feed) video autoplay, and richer quoted-tweet media. In-app video playback
needs the GTK4 GStreamer media backend installed; without it, the viewer's
"Open on X" button plays the clip in the browser.
