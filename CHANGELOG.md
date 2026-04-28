# Changelog

All notable user-facing changes. Older entries are summarised from `git log`; from 0.15.1 forward the release notes on GitHub are the authoritative source and this file mirrors them.

The project follows [semantic versioning](https://semver.org). Breaking changes bump the minor while pre-1.0.

## [Unreleased]

## [0.15.2] — 2026-04-28

- **`o` auto-likes.** Opening a tweet in the browser now likes it on the way out (unless already liked or X is write-rate-limiting). Previously the auto-like only fired in the rate-limited browser-reply fallback path, which had inverted logic and never actually triggered when wanted.
- **Cold-start feed no longer flashes stale.** On the very first Home fetch, the loading screen now stays up until the *newest* tweet has its filter verdict, then the whole sorted feed appears at once. Previously the older, already-classified tail rendered immediately while fresh tweets trickled in over 10–30 s — making it look like you'd reopened to last night's feed.

## [0.15.1] — 2026-04-27

- **Query IDs.** Refreshed `FALLBACK_QUERY_IDS` for eight rotated operations (`TweetResultByRestId`, `TweetDetail`, `HomeTimeline`, `HomeLatestTimeline`, `UserTweets`, `UserTweetsAndReplies`, `SearchTimeline`, `CreateTweet`) detected by the weekly `query-ids-watch` workflow ([#6](https://github.com/guitaripod/unrager/issues/6)).
- **Ollama-missing graceful degradation.** Translation (`T`) now surfaces a visible error instead of hanging silently when Ollama is unreachable; ask (`A`) and brief (`B`) error messages now include a `run \`unrager doctor\`` hint when the failure looks like a connection problem.
- **README.** New "How auth works" section (trust-inducing summary of what cookies are read and what stays local). Explicit Windows support statement (use WSL2 — Windows-native DPAPI cookie decryption isn't implemented).
- **CHANGELOG.** Seeded with the most recent seven releases so the "when was this last touched" check has a clean answer.

## [0.15.0] — 2026-04-21

- **`unrager demo`.** New subcommand that launches the TUI against a bundled offline feed of 15 tweets designed to exercise the rage filter. No cookies, no network. `unrager demo` is the zero-setup way to try the product.
- **`unrager auth setup`.** Interactive wizard that walks a first-time user through registering their X developer-portal app, pastes the Client ID into `config.toml`, and runs `auth login` — one command, one paste.
- **`unrager doctor`.** Infers the browser from `UNRAGER_COOKIES_PATH` instead of always labelling it Vivaldi when the env var is set ([#4](https://github.com/guitaripod/unrager/pull/4)).
- **OAuth client id.** Read from `UNRAGER_X_CLIENT_ID` env var or `[oauth] client_id` in `config.toml` — the embedded default was dropped. Every user's posts are now attributed to their own X app, not a shared identity. `auth login`, `tweet`, and `reply` fail with an explanatory error if neither is configured ([#5](https://github.com/guitaripod/unrager/pull/5)).
- **Status bar.** `filter⌀` glyph replaced with a readable `filter off · doctor` that points at the diagnostic command when the filter silently disables.
- **Published to crates.io.** `cargo install unrager` now works.

## [0.14.2] — 2026-04-21

- **TUI is the default install flavor.** `curl | bash` and `cargo install unrager` now install the TUI. Server + web client becomes opt-in via `UNRAGER_FLAVOR=full` or `--features server`. The CI matrix was realigned to match.
- **Vanity install URL.** `curl -fsSL https://unrager.com/install.sh | bash` proxies to the GitHub installer, so the snippet stays short and brand-local.
- **Landing page** at [unrager.com](https://unrager.com) with OG image, www redirect, and GitHub Actions push-to-deploy.
- **Release automation.** Tags auto-publish to crates.io after the GitHub release is created; every push dry-runs `cargo publish` so we catch packaging regressions before tag day.

## [0.14.1] — 2026-04-20

- **Postcard mode (`S` / `C`).** Rasterize the focal tweet to a PNG with six distinctive themes (`glass`, `synthwave`, `cutout`, `moss`, `blueprint`, `arcade`) or a custom palette. Renders at 2× density (~1400px) with editorial-feel 22pt typography. `s` saves to `~/.cache/unrager/screenshots/`, `y` copies the PNG to your clipboard.

## [0.14.0] — 2026-04-20

- **HTTP server + web/mobile client.** `unrager serve` exposes an axum API and a Dioxus 0.7 web client from the same binary. Pair with Tailscale for multi-device reading; mobile builds (`.app`, `.apk`) share the Rust codebase. Feature parity with the TUI: all sources, compose, thread + reply, filter/ask/brief/translate streaming over SSE, session persistence, settings page, command palette (⌘K).
- **Workspace layout.** `unrager-model` and `unrager-app` are separate crates; feature flags (`tui`, `server`) gate the install footprint from a ~12 MB CLI-only build up to ~23 MB full.
- **Ask: full thread context.** When `A` is pressed inside a detail view, ask walks the full ancestor chain (not just the selected reply), so gemma sees the conversation.
- **`Replies` preset.** Renamed from `Summary`, summarises the dominant reactions and notable disagreements in the thread.

## [0.13.2] — 2026-04-19

- **Mordor-mode audio (opt-in).** Six-layer ambient loop (drone cluster, breathing chant, war drums, descending dirge, Nazgûl screech, noise wash) plays on For You when `UNRAGER_SOUND=1` is set and a source is configured. Playback shells out to `ffplay`/`mpv`/`paplay`/`afplay`/etc. — no audio libraries linked into the binary, ALSA stays out of the build graph. Wallpaper toggle + resize bugs fixed in the same release.
- **Leader key (`<space>`).** New which-key overlay for session toggles: `o` originals, `f` feed, `m` metrics, `n` names, `d` dates, `t` theme, `i` media, `r` filter. Replaces several single-key shortcuts.

## [0.13.1] — 2026-04-19

- **Filter count no longer inflates** on reload. Mordor mode is now gated on both the chosen theme and the terminal's background brightness so a light terminal won't bleed cream through transparent cells under the wallpaper.

## [0.13.0] — 2026-04-18

- **Mordor wallpaper + fiery accents** on the For You feed. Dark-theme + dark-terminal only; ambient whisper and the filter continue regardless.

[Unreleased]: https://github.com/guitaripod/unrager/compare/0.15.2...HEAD
[0.15.2]: https://github.com/guitaripod/unrager/releases/tag/0.15.2
[0.15.1]: https://github.com/guitaripod/unrager/releases/tag/0.15.1
[0.15.0]: https://github.com/guitaripod/unrager/releases/tag/0.15.0
[0.14.2]: https://github.com/guitaripod/unrager/releases/tag/0.14.2
[0.14.1]: https://github.com/guitaripod/unrager/releases/tag/0.14.1
[0.14.0]: https://github.com/guitaripod/unrager/releases/tag/0.14.0
[0.13.2]: https://github.com/guitaripod/unrager/releases/tag/0.13.2
[0.13.1]: https://github.com/guitaripod/unrager/releases/tag/0.13.1
[0.13.0]: https://github.com/guitaripod/unrager/releases/tag/0.13.0
