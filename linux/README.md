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
  text size, image/seen/filter toggles). Distinct from the TUI's config.
- `~/.cache/unrager-gtk/unrager.log` — rolling diagnostics (2 MB + one backup).
- `UNRAGER_BIN` — explicit path to the `unrager` binary if it isn't on `$PATH`
  or `~/.cargo/bin`.
- `UNRAGER_DEFAULT_SERVER` — default server URL (e.g. a Tailscale address) for a
  fresh install.

## Status

Feature-complete against the Apple apps within the server's API ceiling:

- For You / Following / Notifications / Search / Mentions / Bookmarks, with
  thread and profile (header + Brief) drilldown.
- Optimistic like, async avatar/media images, multi-image grids, a media viewer
  with paging, and an Originals toggle on home feeds.
- Compose / reply (copies the draft and opens the X intent, like the Apple apps),
  and the Ask / Brief / Translate streaming LLM sheet.
- Appearance + text size, the rage-filter toggle, a background notifications
  poller with desktop notifications, and keyboard shortcuts (Ctrl+1/2/3/5/6,
  Ctrl+F search, Ctrl+N compose, Ctrl+R refresh, Ctrl+, settings).

Not yet done: inline video playback (needs GStreamer), a shortcuts help window,
and real on-device verification on Linux (the app is currently compile-verified
on macOS; run it on Arch/GNOME for visual QA).
