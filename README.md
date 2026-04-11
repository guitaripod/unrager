# unrager

A calm Twitter/X CLI with a local-LLM rage filter.

`unrager` reads your timeline, threads, mentions, bookmarks, and search results from the command line, then (post-MVP) pipes each tweet through a local Ollama model that drops rage-bait and inflammatory content before it ever reaches your eyes. Posting (tweets and replies) goes through the official X API so your account is never at risk.

## Status

All 8 read commands plus the `tweet` / `reply` write path are implemented. The local-LLM rage filter layer is next. Everything except the live OAuth handshake and the actual paid write call is validated end-to-end against real X data.

## Architecture

Hybrid, by necessity.

- **Reads** use the same GraphQL endpoints X's web client uses, authenticated with cookies pulled directly from your local browser session. This path is free, unquota'd, and returns the exact same data you see in the web app.
- **Writes** use the official X API v2 via OAuth 2.0 PKCE on pay-per-use billing. This costs roughly $0.01 per post (under $2/month at typical personal volume) but carries zero risk to your account, because it is the path X itself wants you to use. Cookie-auth writes are where accounts get suspended; we avoid that entirely.

## Requirements

- Linux with a Secret Service provider (`kwalletd6` on KDE, `gnome-keyring` on GNOME)
- A Chromium-family browser with an active X login. Auto-detected in this order: Vivaldi, Vivaldi Snapshot, Chromium, Chrome (stable / beta / dev), Brave, Edge Dev, Opera. Override with `UNRAGER_COOKIES_PATH=/absolute/path/to/Cookies` to point at any other profile.
- Rust 1.85+ (edition 2024)
- For writes only: an X developer account with OAuth 2.0 configured as a Native App, and a small pay-per-use credit balance at `console.x.com`

## Install

```sh
cargo install --path .
```

Or build and run directly:

```sh
cargo run --release -- whoami
```

## Commands

Read-only (no cost, no API key needed):

| Command | Purpose |
|---|---|
| `unrager whoami` | Confirm which account your cookies belong to |
| `unrager read <id\|url>` | Fetch a single tweet by ID or URL |
| `unrager thread <id\|url>` | Full conversation thread |
| `unrager home [--following]` | Home timeline (For You or Following) |
| `unrager user <@handle>` | A user's recent tweets |
| `unrager search "<query>"` | Live search (any X query operator works) |
| `unrager mentions [--user @h]` | Tweets that mention you (or another handle) |
| `unrager bookmarks "<query>"` | Search within your bookmarks (see note below) |

Every read command accepts `-n <count>`, `--json`, and `--max-pages <n>`.

Write (requires OAuth 2.0 setup and credits):

| Command | Purpose |
|---|---|
| `unrager auth login` | Run the OAuth 2.0 PKCE flow (browser pops, free, no credits consumed) |
| `unrager auth status` | Show the cached token state |
| `unrager auth logout` | Delete the cached token file |
| `unrager tweet "<text>" [--dry-run]` | Post a new tweet (~$0.01) |
| `unrager reply <id\|url> "<text>" [--dry-run]` | Reply to a tweet (~$0.01) |

`--dry-run` on `tweet` and `reply` prints the exact JSON payload that would be sent, with zero network writes — the JSON goes to stdout so you can pipe it somewhere, and the cost preview goes to stderr.

### Note on bookmarks

The full "list all my bookmarks" GraphQL operation lives in a lazy-loaded JavaScript chunk that can only be fetched by executing X's webpack runtime — i.e. you need a real browser. The `BookmarkSearchTimeline` operation that `unrager bookmarks` uses is the only bookmark-related timeline op in `main.*.js`, and it requires a non-empty query. You can search for any substring that appears in the bookmarked tweet's text.

## Security

This tool touches three kinds of credential material:

1. **Browser cookies** (`auth_token`, `ct0`, `twid`) are read at runtime from whichever Chromium-family browser the autodetector finds first, decrypted in memory using a key retrieved from the system Secret Service, and never written to disk. They are never logged, never printed, and never included in error messages. The temporary copy of the `Cookies` SQLite file is created with `tempfile` and deleted on drop.
2. **OAuth 2.0 tokens** (for the write path) are stored in `~/.config/unrager/tokens.json` with mode `0600`, written via a temp-file-then-rename pattern so a crash during write can't leave a truncated file. The `~/.config/unrager` and `~/.cache/unrager` directories are both clamped to `0700` on first access. The file contains your user access token and refresh token; treat it like a password.
3. **OAuth 2.0 Client ID** is embedded as a `const` in the source. This is not a secret — it is the public identifier for the X Developer App, and PKCE public clients are designed around this assumption. There is no Client Secret in the source because the app is registered as a Native App.

If you fork this repo and ship your own binary, replace the Client ID constant in `src/auth/oauth.rs` with your own app's ID and re-register an app under your developer account.

## Legal

This project is not affiliated with, endorsed by, or sponsored by X Corp. It uses X's web GraphQL endpoints in the same way X's own web client does, with the same credentials your browser already holds. Read-only use from a logged-in human operator is the intended use case. Do not use this tool to scrape at scale, run unattended bots, or circumvent account restrictions — you will lose your account and the authors will not help you recover it.

The official X API is used only for posting tweets and replies, under the terms of your own X Developer Agreement.

## License

MIT. See [LICENSE](LICENSE).
