# unrager

A calm Twitter/X CLI with a local-LLM rage filter.

`unrager` reads your timeline, threads, mentions, bookmarks, and search results from the command line, then pipes each tweet through a local Ollama model that drops rage-bait and inflammatory content before it ever reaches your eyes. Posting (tweets and replies) goes through the official X API so your account is never at risk.

## Status

Early. Read commands landing incrementally. Write commands and the rage filter layer come after the read pipeline is stable.

## Architecture

Hybrid, by necessity.

- **Reads** use the same GraphQL endpoints X's web client uses, authenticated with cookies pulled directly from your local browser session. This path is free, unquota'd, and returns the exact same data you see in the web app.
- **Writes** use the official X API v2 via OAuth 2.0 PKCE on pay-per-use billing. This costs roughly $0.01 per post (under $2/month at typical personal volume) but carries zero risk to your account, because it is the path X itself wants you to use. Cookie-auth writes are where accounts get suspended; we avoid that entirely.

A full architectural rationale lives in the `docs/` folder once published.

## Requirements

- Linux with a Secret Service provider (`kwalletd6` on KDE, `gnome-keyring` on GNOME)
- Vivaldi (other Chromium-based browsers work with a small change to the keyring label; Firefox support is a future addition)
- An active X login session in your browser
- Rust 1.85+ (edition 2024)
- For writes only: an X developer account with OAuth 2.0 configured as a Native App, and a small pay-per-use credit balance

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
| `unrager search "<query>"` | Live search |
| `unrager mentions` | Tweets that mention you |
| `unrager bookmarks` | Your bookmarked tweets |

Write (requires OAuth 2.0 setup and credits; see `docs/writes.md`):

| Command | Purpose |
|---|---|
| `unrager tweet "<text>"` | Post a new tweet |
| `unrager reply <id\|url> "<text>"` | Reply to a tweet |

Every read command accepts `-n <count>`, `--json`, and `--max-pages <n>`.

## Security

This tool touches three kinds of credential material. Here is how each is handled.

1. **Browser cookies** (`auth_token`, `ct0`, `twid`) are read at runtime from your Vivaldi profile, decrypted in memory using a key retrieved from the system Secret Service, and never written to disk. They are never logged, never printed, and never included in error messages. The temporary copy of the Cookies SQLite file is created with `tempfile` and deleted on drop.
2. **OAuth 2.0 tokens** (for the write path) are stored in `~/.config/unrager/tokens.json` with mode `0600`. The file contains your user access token and refresh token; treat it like a password.
3. **OAuth 2.0 Client ID** is embedded as a `const` in the source. This is not a secret — it is the public identifier for the X Developer App, and is safe to publish. PKCE public clients are designed around this assumption. There is no Client Secret in the source because the app is registered as a Native App.

If you fork this repo and ship your own binary, replace the Client ID constant with your own app's ID and re-register an app under your developer account.

## Legal

This project is not affiliated with, endorsed by, or sponsored by X Corp. It uses X's web GraphQL endpoints in the same way X's own web client does, with the same credentials your browser already holds. Read-only use from a logged-in human operator is the intended use case. Do not use this tool to scrape at scale, run unattended bots, or circumvent account restrictions — you will lose your account and the authors will not help you recover it.

The official X API is used only for posting tweets and replies, under the terms of your own X Developer Agreement.

## License

MIT. See [LICENSE](LICENSE).
