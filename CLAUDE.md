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
2. Bump `version` in `Cargo.toml` **and** in `browser/extension/manifest.json` (a test fails when they differ; the extension's version is the crate version without any pre-release suffix)
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
  - `seen.rs` — read-tracking sqlite (2-day retention)
  - `session.rs` — session persistence (json)
  - `test_util.rs` — test-only App factory and tweet/page builders
- `src/cli/` — one module per subcommand (whoami, home, read, etc.)
  - `setup.rs` — `unrager setup`: runs `checks::llm`, installs the background service (systemd user unit / launchd agent; only files carrying `MANAGED_MARKER` are ever rewritten, a hand-written unit is just restarted), writes the extension embedded via `include_bytes!` (`EXTENSION_FILES`; tests fail if a file in `browser/extension/` or one the manifest/popup references isn't listed) to `data_dir/browser-extension`, and remembers `--apps`/`--bind` in `data_dir/setup.json`. `--refresh` (hidden) is what `unrager update` runs from the new binary: restart the installed service, rewrite an already-unpacked extension, change nothing else.
  - `checks.rs` — the ✓/!/✗ checks shared by `doctor` and `setup`: model reachability + a real generation for OpenAI-compatible servers, probing common local model-server ports for a paste-ready `[llm]` snippet, `/api/health` of the running server, the unpacked extension's version
- `src/auth/` — chromium cookie extraction + OAuth 2.0 PKCE
- `src/gql/` — GraphQL client, query ID scraper, endpoint builders
- `src/parse/` — response → Tweet/User structs
- `src/store/` — materialized Home buffer + shared caches (gated `any(tui, server)`)
  - `feed.rs` — `FeedStore` over `feed.db`: capped per-variant ring buffer (For You = `ingest_seq DESC`, Following = `created_at DESC`), keyset pagination, `fs2` flock writer lock (`open_writer`/`open_reader`), verdict column, freshness `feed_meta`
  - `about.rs` — `AboutStore` (`about.db`, shared TUI+server) + `AboutFetcher` (single-flight `AboutAccountQuery`, only `Ok` outcomes cached); backs the TUI flag column and `GET /api/about/{rest_id}` (`src/server/routes/about.rs` → `unrager_model::AboutView`, status resolved/none/deferred)
  - `ingest.rs` — background worker (`run`) + `Activity` gate: poll → parse → classify (reusing `FilterCache`/`ClassifierHandle`) → upsert → trim. Parks on **buffer saturation, not idle time** (`buffer_saturated`): it keeps topping the buffer up in the background until For You hits the cap and Following hits the cap or goes "dry" (a poll surfaces nothing new), then parks (no fetching/GPU) until a client wakes it — so the buffer is already large when the app opens. Polls briskly (`active_poll_secs`) only while a client is active (`ACTIVE_WINDOW_SECS`), otherwise the slower `recent_poll_secs` while still filling. (There is no longer an `idle_after_secs` time-based park.)
- `src/model.rs` — Tweet, User, Media, MediaKind
- `src/util.rs` — shared utilities (short_count, parse_tweet_ref)

## iPhone app

The iPhone app talks to a full `unrager serve` (not `--filter-only`: `unrager setup --apps --bind 0.0.0.0:7777`) over HTTP/SSE, paired over Tailscale. It lives in the repo alongside the Rust crates. (The macOS and GNOME clients were removed once the browser extension took over the desktop.)

- `UnragerKit/` — shared Swift package (XcodeGen-independent), Foundation/CoreGraphics only, no UIKit. Holds the byte-exact `Codable` models (matching the `/api/*` JSON, incl. the externally-tagged `MediaKind` and recursive `Tweet`), the typed `APIClient` (async/await + `AsyncThrowingStream` SSE), `URLSessionTransport`, `AppLogger` (file-based, `Library/Logs/unrager.log`), `AppSettings` (server URL + appearance), `Format`, and `ImagePipeline` (off-main ImageIO downsampling → `CGImage`). `swift build && swift test` from `UnragerKit/` verifies it standalone.
- `ios/` — UIKit iPhone app (iOS 26, Liquid Glass). XcodeGen `project.yml` depending on `../UnragerKit`. MVVM + Combine, programmatic Auto Layout, `DesignSystem`/`Glass` tokens, compositional-layout + diffable feed (`FeedViewController`/`TweetCell`), Thread/Profile/Search/Notifications/Settings/Compose/StreamSheet. A `#if DEBUG` `UNRAGER_SCREEN` env router in `SceneDelegate` deep-navigates for screenshot QA; `UNRAGER_SERVER` env / `UNRAGER_DEFAULT_SERVER` Info.plist key sets the server.

Build/run: `cd ios && xcodegen generate && xcodebuild -scheme Unrager -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`, then `xcrun simctl install booted …`. Screenshot QA via `xcrun simctl io <udid> screenshot` driving the `UNRAGER_SCREEN` router. **Not App Store apps** (uses the user's X session) — sideload: `ios/scripts/provision.py` mints an ad-hoc profile (Midgar dist cert + device UDID via the ASC API), `ios/scripts/install-device.sh` builds + ad-hoc-signs + installs via `devicectl`. The iPhone Air's UDID is `00008150-00096C392208401C`; the Mac's Tailscale addr is `100.127.250.64` / `macbook.taila1a09.ts.net`.

When changing the server's `/api/*` contract, update the matching `UnragerKit` model/`APIClient` and the decoding tests in `UnragerKit/Tests/`.

## Browser extension

`browser/extension/` is the main client: a Chromium MV3 extension that filters the official x.com web app, loaded unpacked from the folder `unrager setup` writes (its files are embedded in the binary, so they ship with every release).
- `page-hook.js` runs in `"world": "MAIN"` and observes X's GraphQL `HomeTimeline`/`HomeLatestTimeline` responses (X uses **XMLHttpRequest**; fetch is hooked too) and `postMessage`s the body. It never delays or rewrites what X's page gets. `window.__unrager_status()` in the page console shows the tab's stats.
- `timeline.js` is the JS port of the timeline/tweet walk: the same classification text as `filter::build_classification_text`, retweets mapped to the original's id for DOM matching.
- `content.js` (isolated world) asks `background.js` for verdicts in chunks of 10, each first with `cached_only` (instant, even while the model cold-loads, so already-judged posts hide at once) and then for the rest, remembers up to 400 posts with their text so a resume or a rules change (`rulesChangedAt` in `chrome.storage.local`) can check them again, and marks HIDE cells `data-unrager="hidden"`; `content.css` hides them (never removes React-owned nodes) unless `<html>` carries `data-unrager-paused` or `data-unrager-reveal` (dimmed, "Hidden by unrager" pill). It reports hidden count and state to the badge and answers the popup's `stats` message. Posts the server leaves out are retried twice, 20 s apart.
- `background.js` POSTs to `{server}/api/classify` (`server` in `chrome.storage.local`, default `http://localhost:7777`) and sets the per-tab badge. x.com's CSP blocks page-context fetch to localhost, hence the service-worker hop.
- `popup.{html,css,js}` — status (reads `/api/health` + `/api/filter/status`, compares the server's version with the manifest's), pause, show hidden, the rules editor (`GET`/`PATCH /api/config/filter`), and the server address (non-localhost origins get an optional host permission on save).

Server side: `POST /api/classify` (`src/server/routes/classify.rs`, batch ≤100, shared `FilterCache` + `ClassifierHandle`, omits posts the model failed on; `cached_only: true` answers from the cache alone; each verdict carries the rule behind a hide as `reason` and `overridden` for the user's own call), `GET /api/filter/status` (model state: `ready`/`model_missing`/`unreachable`), `POST /api/filter/overrides` and `GET /api/filter/stats` (`src/server/routes/filter.rs`). Every response carries `x-unrager-version`. `unrager serve --filter-only` (what setup installs) loads no X session and answers only the filter routes; every other route returns 503 `filter_only`. A middleware refuses any request whose `Origin` isn't a browser-extension origin, so web pages can't drive the server (native clients send no `Origin`). Tampermonkey was tried first and abandoned: its userScripts gating silently never injected in Vivaldi.

## Key patterns

**Async events**: background work (fetches, media downloads, filter classification) spawns via `tokio::spawn`, sends results back through `EventTx` as typed `Event` variants. App handles them in `handle_event`. Never block the render loop.

**Semaphores**: media downloads use `Semaphore(4)`, filter classification uses `Semaphore(8)` (shared by every `ClassifierHandle`). Prevents hammering the model server or the CDN.

**Physical removal**: filtered tweets are removed from `source.tweets` on Hide verdict, not hidden via a visibility projection. Keeps cursor math simple.

**Render-time overrides**: the `p` (profile) key doesn't mutate global toggles. `is_own_profile()` is checked when building `RenderOpts` so metrics/names are forced visible only for that source.

**Materialized Home feed**: standing Home feeds (For You + Following) are served from `feed.db` instead of fetched live. The ingest worker (`src/store/ingest.rs`) runs in whichever process holds `feed.db.writer.lock` — `unrager serve` (spawned in `serve()`) or the TUI when no serve is up (`spawn_self_ingest` in `app.rs`); everyone else reads. The TUI fast-path is `App::try_fetch_from_store` in `app_fetch.rs`: it reads a keyset page, **seeds the in-memory `FilterCache` with each row's stored verdict**, and routes the page through the normal `handle_timeline_loaded` — so the existing classification gate treats every row as a cache hit (no Ollama) and shows it instantly, dropping Hide rows and only live-classifying genuinely-unclassified ones. On-demand sources (search/profile/thread/etc.) and a cold buffer fall back to the live path. Background ingest reads go through `GqlClient::post_background`, whose 429s land in a dedicated `ingest_rate_limit_until` bucket (mirroring `about_rate_limit_until`) so they never freeze interactive reads/writes. Freshness is exposed via `GET /api/feed/status` (`src/server/routes/feed.rs` → `unrager_model::FeedStatus`); every client renders an "updated Nm ago" indicator from it (the TUI reads `FeedStore::meta` in-process instead). `buffer_cap` is floored at 1 in both `FeedConfig::load` and `trim_to_cap` so it can never wipe the buffer.

## Logging

Daily rolling log file at `~/.cache/unrager/unrager.log.YYYY-MM-DD` via `tracing-appender`, keeping the `LOG_FILES_KEPT` (14) most recent files. Default level is `info` for the file (captures notification fetch lifecycle, filter decisions, milestone crossings); `--debug` upgrades file output to `debug`. Stderr stays at `warn`.

When debugging a silent failure — a fetch that seems stuck, missing data, a TUI action that does nothing — check the log file first: `tail -f ~/.cache/unrager/unrager.log.$(date +%Y-%m-%d)`. Add `tracing::info!`/`tracing::debug!` calls around any new async work you introduce. Events that deserve logging: spawn start, completion with counts, error paths, silent "skip" branches (loading locks, stale guards). Never use `println!`/`eprintln!` from within the TUI loop — it corrupts the render.

## Config and data paths

- `~/.config/unrager/session.json` — TUI state
- `~/.config/unrager/tokens.json` — OAuth tokens (0600)
- `~/.config/unrager/config.toml` — general settings (browser command, `cookie_browser` pin, query ID overrides)
- `~/.config/unrager/filter.toml` — rage filter rubric, `strictness` and `[llm]` model settings (auto-created from `src/tui/filter_default.toml`; rule edits over the API go through `FilterConfig::write_rules_into`, which keeps comments)
- `~/.local/share/unrager/browser-extension/` — the unpacked extension `unrager setup` writes; `setup.json` beside it remembers setup's `--apps`/`--bind`
- `~/.config/systemd/user/unrager-serve.service` (macOS: `~/Library/LaunchAgents/com.unrager.serve.plist`, log `~/Library/Logs/unrager-serve.log`) — the background server `unrager setup` installs
- `~/.cache/unrager/unrager.log.YYYY-MM-DD` — rolling log file (14 most recent kept)
- `~/.cache/unrager/seen.db` — read tracking (auto-pruned to 2 days)
- `~/.cache/unrager/filter.db` — filter verdict cache with the rule behind each hide (auto-pruned to 7 days; rubric-hash invalidates the rest) and the user's per-post overrides (kept 90 days)
- `~/.cache/unrager/feed.db` — materialized Home buffer (capped ring, `[feed] buffer_cap` default 200/variant); `feed.db.writer.lock` is the `fs2` flock for the single ingest writer
- `~/.cache/unrager/query-ids.json` — scraped GraphQL query ID cache
- `~/.cache/unrager/media/<tweet_id>/` — downloaded attachments for external viewer (`m` key) and screenshot embeds; one subdir per tweet so Linux image viewers can arrow through siblings; whole subdirs LRU-pruned to 512 MB in the background at TUI startup (`external::prune_downloads`)
- `~/.cache/unrager/avatars/<sha256(url)>.bin` — author-avatar disk cache; LRU-pruned to 50 MB on startup; URL-keyed so X's per-upload URL rotation self-invalidates
- `~/.cache/unrager/emoji/<stem>.png` — color emoji PNGs (Twemoji) composited into screenshots; keyed by Twemoji filename stem, cached forever (tiny files)

## Emoji in screenshots

`src/tui/emoji_cache.rs` is the general color-emoji cache for the screenshot rasterizer (`ab_glyph` only draws monochrome outlines, so emoji must be image-composited). `screenshot.rs::paint_buffer` detects any emoji grapheme via `emoji_cache::is_emoji_grapheme` (an exact `emojis`-crate lookup — false-positive-safe against bare digits/`#`/`*`/CJK), maps it to a Twemoji filename stem via `twemoji_stem` (grabTheRightIcon rule: ZWJ present → keep all codepoints, else strip U+FE0F; then lowercase-hex join with `-`), and composites the cached PNG over the cell(s) at `UnicodeWidthStr::width`-many cells. On a miss it falls through to the outline font.

PNGs come from the maintained `jdecked/twemoji` fork (the original `twitter/twemoji` is frozen at Emoji 14.0). The version is **resolved at runtime** once per process via jsDelivr's data API (`resolve-then-pin`), falling back to `FALLBACK_TWEMOJI_VERSION` offline — so the latest emoji render without a rebuild. The only build-time-bound piece is detection: bump the `emojis` crate (and `FALLBACK_TWEMOJI_VERSION`) together when a new Emoji release lands. Flags are no longer special-cased — a flag is just an emoji whose stem is two regional indicators.

## Keeping README in sync

When adding or changing key bindings, features, CLI commands, or config paths, update `README.md` to match. The key bindings table, features section, and config table must stay current.

## Keeping the CHANGELOG in sync

Every user-facing commit (anything a user can notice — key bindings, fetch paths, rendering, CLI commands, defaults, error messages) appends a bullet to `## [Unreleased]` in `CHANGELOG.md` in the same commit, newest at the top of the section. Pure refactors, test changes, dependency bumps, and CI/build-hygiene commits don't need entries.

Match the existing style:

- Lead with a **bolded one-line user-facing claim** — the sentence you'd put in the commit subject — then a body explaining what the user can now do and what was broken if it's a fix.
- No first-person voice. Never write "I", "we", "myself", "us" as the author. The codebase is the subject, not the author. "users" is fine.
- Mechanism detail is welcome in the body when it earns its place, but the body must *support* the user-facing claim — don't open the body with internal symbol names (`submit_reply was reading detail.tweet`); open with what the user sees, then say *why* if it sharpens the picture.
- Don't summarize the diff. Summarize the change in behavior.

If you write a commit and find no `[Unreleased]` bullet matches it, that is the signal to write one — not a signal that the commit is somehow exempt.

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

`T` translates the selected tweet to English via the filter's LLM backend (same `[llm]` config). Translations are ephemeral (in-memory HashMap, cleared on source switch). Press `T` again to revert. The prompt is a zero-temperature `max_tokens: 512` generation with a simple "translate to English" instruction. No caching, no semaphore — it's user-initiated and one-at-a-time.

## LLM backend infrastructure (Ollama + OpenAI-compatible)

`LlmConfig` in `filter.rs` (TOML table `[llm]`; `[ollama]` still loads via a serde alias) is the central type for every LLM call — filter, translate, ask, brief, whisper. `backend = "ollama"` (default) or `"openai"` (any OpenAI-compatible `/v1/chat/completions` server: LM Studio, vLLM, llama-server, SGLang, llama-swap), with an optional `api_key` sent as a bearer token and redacted from `Debug`. It provides:
- `ChatRequest { messages, thinking, temperature, max_tokens }` — backend-neutral; `build_body` translates it (`think`/`options.num_predict` for Ollama, top-level `chat_template_kwargs.enable_thinking`/`max_tokens` for OpenAI-compatible servers — confirmed live on SGLang that `extra_body` nesting is an SDK convention, not wire format)
- `chat()` / `chat_with_client()` — one-shot, parses `{message:{content}}` vs `{choices:[{message}]}`
- `stream_chat()` — dispatches to NDJSON (Ollama) or SSE `data:`/`[DONE]` (parsed by the pure, tested `parse_sse_data_line`)
- `list_models()` / `list_models_within()` (`/api/tags` vs `/v1/models`), `is_served_by()` (Ollama names without a tag mean `:latest`), `supports_vision()` (Ollama only — ask skips image attach otherwise), `build_client()`/`build_streaming_client()`

`rubric_hash` folds in backend + model, so switching either invalidates cached verdicts. Ollama-only residency calls (`ask::preload`/`unload`, `keep_alive`) are no-ops on OpenAI-compatible servers. New LLM features must go through `ChatRequest` + these helpers, never hand-built JSON bodies.

## Filter

One-shot classifier (`thinking: false`, `temperature: 0`, `max_tokens: 8`) built from `filter.toml` by `Rubric`: the topics numbered 1..n, then (unless relaxed) the five built-in `RAGE_BAIT_RULES`, answered as `KEEP` or `HIDE <n>`. `Rubric::judge` maps the number back to the rule's label (a topic's own text, or a built-in's short name), which is the verdict's `reason` (`Judgement`). `strictness` (`Strictness`: relaxed, balanced by default, strict) changes the prompt: relaxed and balanced keep short or unclear posts and say "When in doubt, KEEP", strict judges authors too and says "When in doubt, HIDE". Verdicts cache to sqlite keyed by `(tweet_id, rubric_hash)` with a nullable `reason` column (added in place to older files) — editing the rubric (or strictness, backend, model) invalidates automatically. `classify_once` returns `None` when the backend never answered (unreachable, timeout, malformed reply): every caller shows the tweet but must NOT cache anything, or a cold-loading model pins fake KEEPs for the 7-day retention window. If the backend is down, the filter silently fails open.

`FilterCache::get`/`lookup` answer, in order: the user's own posts (`exempt`, keyed from the `twid` cookie via `XSession::user_id`; always Keep, never judged or stored — the TUI's `prepare_filter_cache`, the ingest worker and the SSE stream mark them), the user's per-post overrides (`overrides` table, set by `POST /api/filter/overrides`, outrank the model in every client, survive rubric changes, pruned after 90 days; another process's overrides arrive through `refresh_overrides`, which rereads them when `PRAGMA data_version` moves), then the model's verdict under the current rubric. `seed` fills memory from `feed.db` rows without writing back. `stats` (behind `GET /api/filter/stats`) counts hides per rule under the current rubric.

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

README images (`assets/extension.png`, `popup.png`, `terminal.png`) are rendered from the landing page's mocks, with mocked posts rather than real accounts: `python3 site/og/assets.py` (Playwright). `site/og/render.py` renders the Open Graph card from `site/og/template.html`; the deploy workflow reruns it.

VHS tapes in `demos/`. Regenerate with `vhs demos/<tape>.tape`. Requires `vhs`, `ttyd`, `ffmpeg`. All tapes use `UNRAGER_DISABLE_KITTY=1` because VHS renders via xterm.js which doesn't support kitty graphics.
