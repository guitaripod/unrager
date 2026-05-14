# Changelog

All notable user-facing changes. Older entries are summarised from `git log`; from 0.15.1 forward the release notes on GitHub are the authoritative source and this file mirrors them.

The project follows [semantic versioning](https://semver.org). Breaking changes bump the minor while pre-1.0.

## [Unreleased]

- **Screenshot composer: metrics off by default + alpha-2 country code in headers.** The compose modal now hides the metrics row (replies / RTs / likes / views / quotes / bookmarks) on every postcard until the user opts in — postcards read cleaner as quote-style cards without the numeric clutter. Toggle inside the modal with `m`; the choice persists in `session.json` (`screenshot_show_metrics`). The author handle also now carries the user's country when known: the live TUI shows a flag emoji, while screenshots render the ISO 3166-1 alpha-2 code (`@bcherny US`) because the bundled monospace font has no flag glyphs and would otherwise rasterize as tofu. Plumbed via a new `FlagStyle::{Emoji, Alpha2}` selector on `RenderOpts`.
- **Country flag + "based in" data next to handles.** Every tweet's author handle now picks up a flag emoji derived from X's own `account_based_in` field (the dropdown that powers the "Account based in: Japan" badge on web profiles), via a new `AboutAccountQuery` GraphQL operation. Country → ISO-3166-1 alpha-2 normalization is delegated to the `celes` crate so we don't ship our own gazetteer; the flag itself is computed from two regional-indicator codepoints. X's `"Europe"` region value maps to 🇪🇺. Lookups are persistent — `~/.cache/unrager/about.db` keys by user `rest_id` (not screen name, so handle renames don't invalidate) and stores the full `about_profile` payload, not just the country. Negative entries (users with no `account_based_in` set) carry a 30-day TTL so we eventually retry users who fill it in later; positive entries never expire because country effectively doesn't change. Fetches run under a `Semaphore(2)` triggered from `handle_timeline_loaded`, dedupe per author across a page, and skip anyone already in the on-disk cache, so a warmed feed adds zero network traffic.
- **`p` profile view shows all available `about_profile` data.** Below the avatar / followers row, the profile header now surfaces: `based in <flag> <country> · via <source> · unverified` (the `source` field reveals *how* X derived the location — App Store region, web fingerprint, etc.; `unverified` is shown when X's own `location_accurate: false` flag is set); `joined <Mon YYYY> · blue since <Mon YYYY>` from `core.created_at` + `verification_info.reason.verified_since_msec`; `affiliated with @<handle>` when the account carries an X affiliate badge (e.g. `@elonmusk` → `@X`); and `N username changes` from `about_profile.username_changes.count` when nonzero — useful for spotting handle-swap or recycled accounts. All fields are optional and only render when X returned a value; profiles with no `about_profile` block degrade silently to the existing avatar + followers header.
- **Screenshot composer hides display names by default.** Postcard screenshots used to bake `Display Name @handle` into the image, which is more identifying than most people want when sharing a quote. The composer modal now renders the focal author (and every thread block) as `@handle` only; press `n` inside the modal to flip back to the full `Display Name @handle` form. The choice persists in `session.json` (`screenshot_show_display_names`) so re-opening the composer keeps your last preference. The live TUI feed is unchanged — this only affects rasterized screenshots.
- **Open URLs from tweet bodies (`M`).** Adds a dedicated key for opening every inline link in the selected tweet. The parser now keeps the `expanded_url` from `entities.urls[]` (previously discarded once the truncated `display_url` had been spliced into the body) in a new `Tweet.urls` field, so `M` has the real URL to hand to the browser. Music streaming links — Spotify, Apple Music, YouTube Music, SoundCloud, Tidal, Amazon Music, Deezer, Pandora — get routed through song.link's `links` endpoint first so readers land on a universal chooser regardless of which service the poster used. Non-music links open directly. If song.link is unreachable the original URL opens as a fallback. Music-host classification is allocation-free (scheme strip + byte-scan to first `/` + `matches!` against a fixed host list) so the parser stays cheap even across large feeds.
- **Inline song.link embed cards.** Tweets with a Spotify / Apple Music / YouTube Music / SoundCloud / Tidal / Amazon Music / Deezer / Pandora link now render an inline card (thumbnail + track title + artist name + `song.link` footer) directly under the body, and the truncated `open.spotify.com/track/3CxJwO1l…` text is stripped so the card *replaces* the URL instead of duplicating it. Metadata is fetched lazily from song.link's `links` endpoint via a new `SongLinkRegistry` mirroring the YouTube oEmbed cache (256-entry LRU, semaphore-of-2 to be polite to the API). Card thumbnails ride the same media pipeline as every other image (kitty-graphics or sextants, on-disk LRU at `~/.cache/unrager/media-cache/`). While the API call is in-flight the card shows a `resolving…` placeholder so layout doesn't shift on arrival. `M` now reuses the cached `pageUrl` from the registry when present, avoiding a second API round-trip on open.

## [0.16.1] — 2026-05-12

- **Image rendering — six bugs gone.** (1) Same image rendering at two locations simultaneously (e.g. a media tweet visible in both the feed and the open detail pane) no longer clobbers itself: each placement now uses a distinct kitty placement id (`p=` parameter) packed from `(cols, rows)` and encoded via the underline color of every placeholder cell, so the terminal routes each placeholder grid to its correct placement rectangle. (2) Cell pixel size is re-queried via ioctl on terminal resize — previously frozen at startup, so a font-size change, monitor swap, or failed initial detection on Arch baked stale dimensions in until restart. The placement cache is invalidated on change so every visible image re-emits at the new size. (3) Multiplexer detection: `TMUX` / `ZELLIJ_SESSION_ID` falls back to halfblocks instead of emitting kitty graphics the multiplexer silently drops. Override with `UNRAGER_FORCE_KITTY_IN_MUX=1` if you've configured tmux `allow-passthrough`. (4) The placement-emit + ratatui draw pair is now wrapped in `DECSET 2026` / `DECRST 2026` (Begin/End Synchronized Update) so terminals see one atomic frame instead of a placement followed by a placeholder grid with a paintable gap in between. Escape hatch: `UNRAGER_DISABLE_SYNC_UPDATE=1`. (5) Tweet media URLs on `pbs.twimg.com/media/*` now request `?name=small` (~680 px) at fetch time — we downscale to 800 px anyway, so the previous full-resolution fetch wasted bandwidth and decode CPU; the rewrite happens at the HTTP request site only, so the original URL stays the cache and dedup key. (6) Tweet media caches to disk at `~/.cache/unrager/media-cache/<sha256(url)>.bin`, 200 MB LRU cap, mirroring the avatar cache — repeated browsing of the same feed feels instant.
- **Detail-view reply avatars.** `ensure_tweet_resources` (called when a thread's replies load) now queues each reply author's avatar so the chip actually appears in the gutter. The placement code was already wired and the gutter was already reserved — the avatar was just never downloaded for reply authors, so `media_reg.get(url)` returned `None` and the gutter rendered blank.
- **`o` no longer likes your own tweets.** Opening your own post in the browser used to auto-like it on the way out — same path the 0.15.2 change wired up. Now `o` checks the author against your resolved `self_handle` and skips the like for own tweets while keeping the auto-like for everyone else's.
- **Detail-view analytics block for your own tweets.** When the focal tweet in the detail pane is yours, an extra panel below the body breaks out views / likes / retweets / replies / quotes / bookmarks plus an engagement-rate line `(likes+RTs+replies+quotes+bookmarks) / views`. Includes `bookmark_count`, which X exposes on every tweet but unrager was previously ignoring. The deeper "post analytics" page (impressions, profile visits, link clicks, new follows) is not yet wired — that endpoint lives in a chunk-loaded JS bundle and needs a separate scraper pass.
- **Avatar on profile pages.** Navigating to a user with `p` now resolves the full profile via `UserByScreenName` (already called for the rest_id) and pins a small kitty-graphics avatar plus name / handle / followers / following at the top of the source pane. Falls back to a text-only header on non-kitty terminals or while the image is downloading. Captured via a new `User.avatar_url` and `Source.profile_user`.
- **Author-avatar chips in feeds.** Every tweet row in the source pane, detail focal, detail reply chain, and inline thread replies now reserves a gutter for a square kitty-graphics chip of the author's avatar. The chip's cell footprint adapts to the terminal's cell aspect so a 1:1 source image renders as a real square (no stretching). The redundant unread-dot column is dropped — the chip is the read indicator and the body's bold-on-unread weight is the read/unread signal. Toggle with `<space> a` — when off, downloads are skipped and the gutter is suppressed. Persisted in `session.json`. Kitty-only feature; halfblock and disabled terminals fall back to the no-gutter layout.
- **Avatar disk cache.** Author avatars now cache at `~/.cache/unrager/avatars/<sha256(url)>.bin` so re-opening unrager is instant — no flicker waiting for the network. The URL-keyed cache is self-invalidating because X rotates the URL's image-hash segment whenever a user changes their picture: a new avatar arrives as a new cache entry, never a stale read. LRU-pruned to 50 MB on startup; corrupt entries are deleted and refetched; write failures fall back to in-memory only.
- **Avatars in screenshots.** `S` / `C` shots (single tweet and thread) now composite the author's avatar into the top-left gutter of every block. The rasterizer can't read kitty placeholders, so the screenshot path loads the avatar separately (from the same on-disk cache, falling back to HTTP), scales it to the screenshot grid's own cell aspect so it stays square, and overlays it after the text buffer is painted. Disabling feed avatars (`<space> a`) also suppresses screenshot avatars.
- **Dedupe per-frame kitty placements.** `emit_media_placements` previously re-issued an `a=p,U=1,i=…,c=…,r=…` command for every visible image on every frame. On Ghostty/Linux that floods the graphics queue: placeholder cells paint before the matching placement is processed, so images briefly inherit a stale grid and "settle" to the right size after a second or two (mismatched avatars, tweet media rendered tiny, etc.). `MediaRegistry::place(id, cols, rows)` now caches the last successful `(cols, rows)` per image and only writes to stdout on a diff. Eviction drops the cache entry so a re-fetched id starts fresh; resizing/scrolling that genuinely changes c,r naturally invalidates and re-emits.

## [0.16.0] — 2026-05-08

- **Postcard thread mode (`T` in composer).** Capture an entire reply chain as one image — root tweet down to the focal — with a continuous accent bar running through every block and subtle hairline dividers between them. Toggling thread mode in the screenshot modal walks `in_reply_to_tweet_id` up to the root via the `TweetDetail` GraphQL endpoint (already loaded for thread context elsewhere); media images on every ancestor are downloaded and composited under their respective tweets. Each reply block strips the leading `@parent` mention chain and the `↳` icon since the visual stack already communicates the chain. Watermark sits once at the bottom. Capped at 20 ancestors to bound runaway chains.
- **Postcard icons + Norse runes no longer render as tofu.** ✓ ↳ ⟲ ♥ ♡ ↻ ⮎ ✗ and Runic-block characters (U+16A0..U+16F8) were all rasterizing as `□` because the bundled NotoSansMono font doesn't include them. Added subsetted NotoSansMath, NotoSansSymbols2, and NotoSansRunic (~17 KB combined) as fallback fonts; the rasterizer now picks per-glyph from primary → math → symbols2 → runic.
- **Postcard media path now logs.** Picture fetch/decode used to fail silently; the screenshot pipeline now emits `info` logs for target collection, fetch, decode, and totals so a missing image is visible in `unrager.log.YYYY-MM-DD`.

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

[Unreleased]: https://github.com/guitaripod/unrager/compare/0.16.1...HEAD
[0.16.1]: https://github.com/guitaripod/unrager/releases/tag/0.16.1
[0.16.0]: https://github.com/guitaripod/unrager/releases/tag/0.16.0
[0.15.2]: https://github.com/guitaripod/unrager/releases/tag/0.15.2
[0.15.1]: https://github.com/guitaripod/unrager/releases/tag/0.15.1
[0.15.0]: https://github.com/guitaripod/unrager/releases/tag/0.15.0
[0.14.2]: https://github.com/guitaripod/unrager/releases/tag/0.14.2
[0.14.1]: https://github.com/guitaripod/unrager/releases/tag/0.14.1
[0.14.0]: https://github.com/guitaripod/unrager/releases/tag/0.14.0
[0.13.2]: https://github.com/guitaripod/unrager/releases/tag/0.13.2
[0.13.1]: https://github.com/guitaripod/unrager/releases/tag/0.13.1
[0.13.0]: https://github.com/guitaripod/unrager/releases/tag/0.13.0
