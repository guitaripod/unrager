# Development

## Build

```sh
cargo build --release
cargo install --path .   # installs to ~/.cargo/bin/unrager
```

Nightly rustc may SIGILL during release LTO. `.cargo/config.toml` sets `RUST_MIN_STACK=128M` to work around it. Stable toolchain doesn't need it.

## CI gate

Every push runs these three checks. Run locally before committing:

```sh
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test
```

Always run the CI gate after making changes, without waiting to be asked. Then `cargo install --path .` so the user can immediately run the updated binary.

## Releasing a new version

1. Roll the `## [Unreleased]` section in `CHANGELOG.md` into a new `## [X.Y.Z] — YYYY-MM-DD` entry, add a fresh empty `[Unreleased]`, and update the link refs at the bottom of the file
2. Bump `version` in `Cargo.toml`
3. `cargo check` to update `Cargo.lock`
4. Commit: `chore: bump version to X.Y.Z` (include the CHANGELOG edit in the same commit)
5. Tag (no `v` prefix): `git tag X.Y.Z`
6. Push both: `git push origin master --tags`
7. The `release` workflow runs CI checks, creates the GitHub release, then publishes `unrager-model` + `unrager` to crates.io — **never create releases manually with `gh release create` or `cargo publish`**
8. After the workflow completes, edit the GitHub release body and paste the CHANGELOG section verbatim so the release page matches the file

Do NOT force-push tags that already have a release. If post-release fixes are needed, they go into the next version.

The crates.io step reads `CARGO_REGISTRY_TOKEN` from repo secrets. Each publish is guarded by a crates.io existence check, so re-running the workflow (e.g. after a transient failure) won't double-publish — it skips versions that are already uploaded.

## Architecture

- `src/main.rs` — clap dispatch: bare `unrager` → TUI, subcommands → one-shot CLI
- `src/tui/` — the TUI (ratatui + crossterm + tokio async event loop)
  - `app.rs` — App struct, construction, `handle_event` dispatch, core utilities
  - `app_keys.rs` — all key handlers (main dispatch, source/detail/command/ask/brief panes)
  - `app_fetch.rs` — async fetch dispatch + result handling (timelines, threads, notifications, likers)
  - `app_llm.rs` — filter classification, translate, ask view, brief/profile view
  - `app_nav.rs` — source switching, history, browser/clipboard, engagement, feed toggles
  - `ui.rs` — all rendering (draw functions, tweet_lines, help overlay)
  - `filter.rs` — rage filter (Ollama classifier, sqlite cache, rubric parsing, shared Ollama helpers)
  - `media.rs` — kitty graphics (transmit, placeholders, registry)
  - `source.rs` — Source struct, fetch_page dispatchers for all feed types
  - `focus.rs` — TweetDetail for the detail pane (focal + replies)
  - `event.rs` — Event enum, event loop with tick/render/key/resize
  - `seen.rs` — read-tracking sqlite (30-day retention)
  - `session.rs` — session persistence (json)
  - `test_util.rs` — test-only App factory and tweet/page builders
- `src/cli/` — one module per subcommand (whoami, home, read, etc.)
- `src/auth/` — chromium cookie extraction + OAuth 2.0 PKCE
- `src/gql/` — GraphQL client, query ID scraper, endpoint builders
- `src/parse/` — response → Tweet/User structs
- `src/model.rs` — Tweet, User, Media, MediaKind
- `src/util.rs` — shared utilities (short_count, parse_tweet_ref)

## Key patterns

**Async events**: background work (fetches, media downloads, filter classification) spawns via `tokio::spawn`, sends results back through `EventTx` as typed `Event` variants. App handles them in `handle_event`. Never block the render loop.

**Semaphores**: media downloads use `Semaphore(4)`, filter classification uses `Semaphore(2)`. Prevents hammering Ollama or the CDN.

**Physical removal**: filtered tweets are removed from `source.tweets` on Hide verdict, not hidden via a visibility projection. Keeps cursor math simple.

**Render-time overrides**: the `p` (profile) key doesn't mutate global toggles. `is_own_profile()` is checked when building `RenderOpts` so metrics/names are forced visible only for that source.

## Logging

Daily rolling log file at `~/.cache/unrager/unrager.log.YYYY-MM-DD` via `tracing-appender`. Default level is `info` for the file (captures notification fetch lifecycle, filter decisions, milestone crossings); `--debug` upgrades file output to `debug`. Stderr stays at `warn`.

When debugging a silent failure — a fetch that seems stuck, missing data, a TUI action that does nothing — check the log file first: `tail -f ~/.cache/unrager/unrager.log.$(date +%Y-%m-%d)`. Add `tracing::info!`/`tracing::debug!` calls around any new async work you introduce. Events that deserve logging: spawn start, completion with counts, error paths, silent "skip" branches (loading locks, stale guards). Never use `println!`/`eprintln!` from within the TUI loop — it corrupts the render.

## Config and data paths

- `~/.config/unrager/session.json` — TUI state
- `~/.config/unrager/tokens.json` — OAuth tokens (0600)
- `~/.config/unrager/config.toml` — general settings (browser command, query ID overrides)
- `~/.config/unrager/filter.toml` — rage filter rubric (auto-created)
- `~/.cache/unrager/unrager.log.YYYY-MM-DD` — rolling log file
- `~/.cache/unrager/seen.db` — read tracking (auto-pruned to 30 days)
- `~/.cache/unrager/filter.db` — filter verdict cache (auto-pruned to 30 days)
- `~/.cache/unrager/query-ids.json` — scraped GraphQL query ID cache
- `~/.cache/unrager/media/<tweet_id>/` — downloaded attachments for external viewer (`m` key); one subdir per tweet so Linux image viewers can arrow through siblings

## Keeping README in sync

When adding or changing key bindings, features, CLI commands, or config paths, update `README.md` to match. The key bindings table, features section, and config table must stay current.

## Adding a new key binding

1. Add the match arm in `handle_key` (global) or `handle_key_source`/`handle_key_detail` (pane-specific) in `app_keys.rs`
2. Add a help entry in `draw_help_overlay` in `ui.rs`
3. Bump the help popup height cap in `draw_help_overlay` if the content grows past it

## Adding a new source type

1. Add a variant to `SourceKind` in `source.rs` (with serde)
2. Add a fetch function and wire it into `fetch_page`
3. Add a command parser branch in `command.rs`
4. Classification and media queueing happen automatically via `handle_timeline_loaded`

## Feed modes

`V` toggles between All and Originals on Home feeds. Originals mode filters out replies (`in_reply_to_tweet_id.is_some()`), quote tweets (`quoted_tweet.is_some()`), and retweets (`text.starts_with("RT @")`). Filtering happens in `handle_timeline_loaded` at load time — toggling reloads the source. Persisted in session as `feed_mode`.

## Translation

`T` translates the selected tweet to English via Ollama (same model/host as the filter). Translations are ephemeral (in-memory HashMap, cleared on source switch). Press `T` again to revert. The Ollama prompt is a zero-temperature `num_predict: 512` generation with a simple "translate to English" instruction. No caching, no semaphore — it's user-initiated and one-at-a-time.

## Ollama shared infrastructure

`OllamaConfig` in `filter.rs` is the central type for all Ollama interactions. It provides:
- `chat_url()` — builds the `/api/chat` URL
- `build_client()` — creates a reqwest client with the configured timeout
- `build_streaming_client()` — same but with `max(timeout, 180s)` for streaming
- `stream_chat()` — generic NDJSON streaming core with token/thinking callbacks, used by both ask and brief
- `OllamaChatResponse` — shared deserialization type for non-streaming responses

New Ollama features should use these helpers rather than building clients and parsing responses manually.

## Filter

Ollama `POST /api/chat` with `think: false`, `temperature: 0`, `num_predict: 3`. Prompt is a one-shot HIDE/KEEP classifier built from `filter.toml` topics. Verdicts cache to sqlite keyed by `(tweet_id, rubric_hash)` — editing the rubric invalidates automatically. If Ollama is down, filter silently disables.

## Media

Kitty graphics via Unicode virtual placements. Images downscaled to 400px max before transmit. Placement commands emitted per-frame with current pane width. `UNRAGER_DISABLE_KITTY=1` env var disables detection for testing/recording.

## Sound

`src/tui/sound.rs` supports two user-supplied sources, tried in order: (1) `[sound] source = "..."` in `config.toml` — slices/fades/downmixes/encodes via `ffmpeg` to a hash-cached Opus file (`~/.cache/unrager/mordor-user-<hash>.opus`), hash keyed on `(source, mtime, start, duration, fade_ms, volume)` so edits invalidate automatically; (2) a pre-encoded file the user drops at `config_dir/mordor-sound.{opus,ogg,oga,flac,mp3,wav}` — used raw. No built-in synthesized fallback: if no source is configured, Mordor mode is silent. Opt-in via `UNRAGER_SOUND=1`. Six stacked layers: (1) A1 + E♭2 tritone + detuned A1 drone cluster whose 0.125 Hz beating period equals the loop length so the pulse phase-locks; (2) A2 + D♯3 + F3 breathing chant with 5 Hz tremolo, windowed by `sin²(π·t/4)` for two swells per loop; (3) war drums — "great drum" on beats 1/5 (80→30 Hz pitch sweep, 200 ms decay), "kick" on beats 4/8 (150→45 Hz, 120 ms decay); (4) two-octave descending chromatic-ish dirge E3 → D3 → C3 → B2 → A2 → G2 → F♯2 → E2 (one note per beat, 200 ms fades); (5) Nazgûl screech at t=5.5 s — fundamental + octave harmonic square waves with 8 Hz vibrato and noise hiss, quadratic fade; (6) very quiet pink-ish noise wash windowed once per loop for dread texture. Continuous-layer frequencies are integer multiples of `1 / DURATION_SECS = 0.125 Hz` for seamless phase wrap; enveloped layers fade to zero at their boundaries. Backend detection is format-aware (`Backend::supports(AudioFormat)`): `ffplay`/`mpv` play anything, `paplay` speaks WAV/FLAC/Ogg via libsndfile, `aplay`/`pw-play` are WAV-only, `afplay` (macOS) handles WAV/MP3/FLAC. The first backend on `$PATH` that decodes the chosen file wins. Prefers `ffplay -loop 0` / `mpv --loop=inf` for gapless playback; falls back to a `sh -c 'while :; do …; done'` wrapper around the WAV-capable players. No Rust audio dep is linked — ALSA stays out of the build graph, shipped binaries don't pull `libasound` at load time. `App::sync_mordor_sound` fires on the edge transitions of `mordor_active()` (`start_loop` on false→true, `stop_loop` on true→false) at the end of every `handle_event` tick. `Player` implements `Drop` so the child process dies when `App` goes out of scope. Bump `SOUND_VERSION` when the loop changes so existing cached WAVs get regenerated.

## Query IDs

GraphQL operations require query IDs that X rotates on deploy. The `scraper` module extracts them from the main.js bundle. Fallback IDs are hardcoded in `FALLBACK_QUERY_IDS`. When the scraper fails (X obfuscates the bundle), the client falls back to cached or hardcoded IDs, which may go stale.

Manual overrides via `config.toml`:
```toml
[query_ids]
HomeTimeline = "abc123"
SearchTimeline = "def456"
```

`unrager doctor` reports cache age, scraper health, and active overrides.

## App module structure

`App` state lives in `app.rs`. Methods are split across sibling files by responsibility:
- `app_keys.rs` — key input handling (add new key bindings here)
- `app_fetch.rs` — data fetching + result handling (add new fetch/load cycles here)
- `app_llm.rs` — LLM features: ask, brief, translate, filter classification
- `app_nav.rs` — source switching, history, browser actions, engagement, toggles

Each file does `impl App { ... }` — Rust allows splitting impl blocks across modules. Methods use `pub(super)` visibility for cross-module calls within `tui/`.

## Testing

Integration tests for App state transitions use `tui/test_util.rs` which provides `dummy_app()` (constructs an App with dummy GqlClient and channels), `make_tweet()`, and `make_page()`. Tests that trigger `tokio::spawn` (switch_source, push_tweet, engage, etc.) need `#[tokio::test]`. Pure state-mutation tests can use `#[test]`.

## Demos

VHS tapes in `demos/`. Regenerate with `vhs demos/<tape>.tape`. Requires `vhs`, `ttyd`, `ffmpeg`. All tapes use `UNRAGER_DISABLE_KITTY=1` because VHS renders via xterm.js which doesn't support kitty graphics.
