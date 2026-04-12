# unrager

A calm Twitter/X client for the terminal, with a local-LLM filter that drops inflammatory content before it ever reaches your eyes.

Two modes in one binary. Run `unrager` with no arguments to launch the interactive TUI; pass a subcommand (`whoami`, `home`, `read`, `search`, etc.) for a one-shot CLI call.

```
unrager             # TUI
unrager home -n 20  # one-shot CLI
unrager tweet "..."  # post via official API
```

## What it does

- **Reads** your home timeline, threads, mentions, bookmarks, and search from the same GraphQL endpoints X's web client uses, authenticated with cookies pulled directly from your logged-in Chromium-family browser. Free, unquota'd, full personalization.
- **Filters** every tweet in a root feed through a local [Ollama](https://ollama.com) `gemma4` model (or any model you configure) against a user-editable rubric in `~/.config/unrager/filter.toml`. Matches are physically removed from the feed. Verdicts cache to SQLite so reloads are instant and rubric edits invalidate the cache automatically. Toggle on/off with `c`.
- **Writes** tweets and replies via the official X API v2 over OAuth 2.0 PKCE on pay-per-use billing. No ban risk on your main account — cookie-auth writes are where X's anti-bot ML lives, and we avoid that entirely.
- **Renders** media inline via the [kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) when running in a compatible terminal (Ghostty, Kitty, WezTerm). Falls back to colored badges elsewhere.

## TUI features

- Split detail pane: focal tweet + replies in one scrollable list
- Color-hashed `@handles` (FNV-1a → 20-color palette, deterministic and consistent across body mentions)
- Zebra-striped rows, terminal-theme-aware body text (OSC 11 background probe at startup)
- Word-wrapped body lines, variable-height cards, scroll look-ahead
- Compact relative timestamps, hidden zero-count stats
- Persistent per-session preferences (metrics visibility, display names, timestamps style) in `session.json`
- Inline thread toggle (`X`) in the detail pane
- In-place body expansion (`x`), open in browser (`o`), yank URL (`y`) / JSON (`Y`)
- Command palette (`:`) with `:home`, `:user`, `:search`, `:mentions`, `:bookmarks`, `:read`, `:thread`
- History back/forward (`[` / `]`)
- `?` overlay for the full key reference

## Demos

Scriptable VHS tapes live in [`demos/`](demos/). Each `.tape` produces a GIF, MP4, and PNG screenshots into `demos/out/`. See [`demos/README.md`](demos/README.md) for how to regenerate.

| file | what it shows |
|---|---|
| `demos/home.tape` | launch + home feed + scroll |
| `demos/filter.tape` | `c` toggle — filter on vs off |
| `demos/detail.tape` | detail pane navigation |
| `demos/expand.tape` | `x` body expansion |
| `demos/help.tape` | `?` overlay |
| `demos/command.tape` | `:user`, `:search` |
| `demos/overview.tape` | the grand tour |

Note: VHS renders through xterm.js which doesn't speak the kitty graphics protocol. The demos force `UNRAGER_DISABLE_KITTY=1` so the TUI falls back to colored header icons instead of leaking placeholder cells. For a real media demo, screen-record a live Ghostty window with `kooha`, `wf-recorder`, or OBS.

## Architecture

Hybrid, by necessity.

- **Reads** use the same GraphQL endpoints X's web client uses, authenticated with cookies pulled from your local Chromium-family browser session. This path is free, unquota'd, and returns the exact same data you see in the web app.
- **Writes** use the official X API v2 via OAuth 2.0 PKCE on pay-per-use billing. Every call to `/2/tweets` and every call to `/2/media/upload` is a separate "Content-create" request billed to your credit balance. A text-only tweet is 1 request; a tweet with 1 single-shot image is 2 requests; a tweet with a chunked video is (2 + N segments) upload calls + 1 tweet call. Zero account risk because this is the path X itself wants you to use.
- **Filter** spawns classification tasks per tweet on page load through a `tokio::sync::Semaphore(2)`. Each hits `POST http://localhost:11434/api/generate` with `think: false`, `temperature: 0`, `num_predict: 10`. Verdicts are cached to SQLite keyed by `(tweet_id, rubric_hash)`; rubric edits automatically invalidate without re-classifying anything.

See the commit history and `src/` for the code.

## Requirements

- Linux with a Secret Service provider (`kwalletd6` on KDE, `gnome-keyring` on GNOME)
- A Chromium-family browser with an active X login. Auto-detected in order: Vivaldi, Vivaldi Snapshot, Chromium, Chrome (stable/beta/dev), Brave, Edge Dev, Opera. Override with `UNRAGER_COOKIES_PATH=/absolute/path/to/Cookies` for any other profile.
- Rust 1.85+ (edition 2024)
- Optional, for the rage filter: Ollama running locally with a model pulled. Default is `gemma4:latest`, configurable in `~/.config/unrager/filter.toml`.
- Optional, for writes: an X developer account with OAuth 2.0 configured as a Native App, plus pay-per-use credits at [console.x.com](https://console.x.com).

## Install

```sh
cargo install --path .
```

Or build and run directly:

```sh
cargo run --release
```

## Commands

### Read-only (no cost, no API key)

| Command | Purpose |
|---|---|
| `unrager whoami` | Confirm which account your cookies belong to |
| `unrager read <id\|url>` | Fetch a single tweet by ID or URL |
| `unrager thread <id\|url>` | Full conversation thread |
| `unrager home [--following]` | Home timeline (For You or Following) |
| `unrager user <@handle>` | A user's recent tweets |
| `unrager search "<query>"` | Live search (any X query operator works) |
| `unrager mentions [--user @h]` | Tweets that mention you (or another handle) |
| `unrager bookmarks "<query>"` | Search within your bookmarks |

Every read command accepts `-n <count>`, `--json`, and `--max-pages <n>`.

### Write (requires OAuth 2.0 setup and credits)

| Command | Purpose |
|---|---|
| `unrager auth login` | Run the OAuth 2.0 PKCE flow (browser pops, free) |
| `unrager auth status` | Show cached token state |
| `unrager auth logout` | Delete the cached token file |
| `unrager tweet "<text>" [--dry-run]` | Post a new tweet (~$0.01) |
| `unrager reply <id\|url> "<text>" [--dry-run]` | Reply to a tweet (~$0.01) |

`--dry-run` prints the exact JSON payload that would be sent, with zero network writes. JSON goes to stdout, cost preview to stderr.

## Configuration

| File | Purpose |
|---|---|
| `~/.config/unrager/session.json` | TUI session state (current source, selection, toggles) |
| `~/.config/unrager/tokens.json` | OAuth 2.0 access/refresh tokens (mode `0600`) |
| `~/.config/unrager/filter.toml` | Rage filter rubric (auto-created on first launch) |
| `~/.cache/unrager/seen.db` | SQLite store of read tweets (for unread counter) |
| `~/.cache/unrager/filter.db` | SQLite store of filter verdicts |

Both config and cache directories are created with mode `0700` on first access.

## Security

1. **Browser cookies** (`auth_token`, `ct0`, `twid`) are read at runtime from whichever Chromium-family browser the autodetector finds first, decrypted in memory using a key retrieved from the system Secret Service, and never written to disk. Never logged, never printed, never in error messages. The temporary copy of the `Cookies` SQLite file is created with `tempfile` and deleted on drop.
2. **OAuth 2.0 tokens** are stored in `~/.config/unrager/tokens.json` mode `0600`, written via temp-file-then-rename so a crash during write can't leave a truncated file.
3. **OAuth 2.0 Client ID** is embedded as a `const` in `src/auth/oauth.rs`. This is not a secret — it's the public identifier for a PKCE public client. If you fork and ship your own binary, replace the constant with your own Native App ID.
4. **Filter classification** runs entirely locally against Ollama. Tweet text never leaves your machine unless you explicitly post it.

## Legal

This project is not affiliated with, endorsed by, or sponsored by X Corp. It uses X's web GraphQL endpoints in the same way X's own web client does, with the same credentials your browser already holds. Read-only use from a logged-in human operator is the intended use case. Do not use this tool to scrape at scale, run unattended bots, or circumvent account restrictions — you will lose your account and the authors cannot help you recover it.

The official X API is used only for posting tweets and replies, under the terms of your own X Developer Agreement.

## Contributing

Issues and PRs welcome. Before submitting:

```sh
cargo fmt --all
cargo clippy --all-targets -- -D warnings
cargo test
```

CI runs the same three checks on push and PR.

## License

MIT. See [LICENSE](LICENSE).
