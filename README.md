<p align="center">
  <h1 align="center">unrager</h1>
  <p align="center">
    A calm Twitter/X client for the terminal.<br>
    Local LLM drops rage-bait before it reaches your eyes.
  </p>
  <p align="center">
    <a href="https://github.com/guitaripod/unrager/actions"><img src="https://img.shields.io/github/actions/workflow/status/guitaripod/unrager/ci.yml?branch=master&style=flat-square&label=ci" alt="CI"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="GPL-3.0 License"></a>
    <img src="https://img.shields.io/badge/rust-1.85%2B-orange?style=flat-square&logo=rust" alt="Rust 1.85+">
  </p>
</p>

<p align="center">
  <img src="assets/feed.png" alt="unrager home feed with rage filter active" width="800">
</p>

Your home feed, minus the 12 tweets the LLM quietly ate. The `−12` in the status bar is all that remains of them.

## What is this

`unrager` is a Rust TUI for reading Twitter/X without the engagement-optimized rage. It connects through the same GraphQL endpoints the web client uses (no API key, no cost), and pipes every incoming tweet through a local [Ollama](https://ollama.com) model that classifies it against your personal rubric. Tweets that match are physically removed from the feed before rendering — they never existed.

It also has a CLI for one-shot reads and an OAuth 2.0 write path for posting.

```
unrager               # TUI
unrager home -n 20    # one-shot CLI
unrager tweet "..."   # post via official API
```

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/unrager/master/install.sh | bash
unrager

# optional: enable the rage filter
ollama pull gemma4
```

Uninstall:

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/unrager/master/install.sh | bash -s -- --uninstall
```

Works on macOS (Apple Silicon + Intel) and Linux (x86_64 + aarch64). Builds from source via `cargo install --path .` on any platform with Rust 1.85+.

The TUI reads cookies from your logged-in browser automatically (Vivaldi, Chrome, Brave, Edge, Opera, Arc). The filter enables itself when Ollama is reachable and disables silently when it isn't.

## The rage filter

Every tweet is classified by a local LLM against a user-editable rubric (`~/.config/unrager/filter.toml`). Matching tweets are physically removed — not collapsed, not grayed out, gone. Verdicts cache to SQLite keyed by `(tweet_id, rubric_hash)`, so reloads are instant and editing the rubric invalidates automatically.

```toml
drop_topics = [
    "american electoral politics, presidents, congress, partisan fights",
    "war, military conflict, battlefield footage, casualty counts",
    "gender wars, men-vs-women discourse, trad-vs-feminist fights",
    # add your own
]
extra_guidance = "Keep technical, scientific, art, music, sports tweets..."

[ollama]
model = "gemma4:latest"
host = "http://localhost:11434"
```

Toggle with `c`. The status bar shows `−N` when the filter is actively hiding tweets, or `filter⌀` (dim) when Ollama isn't reachable or no `gemma4` model is installed — `unrager doctor` explains why.

## Reading threads

<p align="center">
  <img src="assets/detail.png" alt="split pane showing a tweet with replies sorted by likes" width="800">
</p>

`Enter` opens a tweet into a split detail pane. The focal tweet and all its replies form one scrollable list. Push deeper into any reply with `Enter`, pop back with `h`. Press `s` to cycle reply sort order — newest, likes, replies, retweets, views — it persists across sessions. `X` expands inline thread replies without leaving the current view.

Submitting a reply with `r` auto-likes the tweet you're replying to (unless it's already liked) — reciprocal-like etiquette without the manual step. If X is write-rate-limiting you and you fall back to the browser via `o` to compose there, the TUI still fires the auto-like on your behalf.

The left pane stays live. `Tab` swaps focus between panes, `,`/`.` adjusts the split width.

## Search and translation

<p align="center">
  <img src="assets/search.png" alt="search results for nvidia with multilingual content and translation" width="800">
</p>

`:search nvidia` pulls live results in every language. Press `T` on any tweet to translate it to English via the same local Ollama instance. Press `T` again to revert. Translations are ephemeral — in memory only.

Press `A` on any tweet to open an ask pane powered by your local Ollama gemma model (the same one used for the rage filter and translation). The post is pinned to the top, a chip row exposes preset prompts (`1` Explain · `2` Summary · `3` Counter · `4` ELI5 · `5` Entities) that fire with a single keystroke when the input is empty, and the reply streams inline token-by-token. Gemma4's vision is used automatically — up to four photos on the post are base64-attached to the first turn. When you open the pane from the detail view, the loaded replies are pulled into context, so `2 Summary` actually summarizes the thread; the pane title shows what's in scope (`ask · @handle · 2 imgs · 14 replies · ready`). Conversations live only in memory. Thinking is enabled for the chat path since replies benefit from reasoning; filter and translate keep thinking off for speed.

The command palette supports `:home`, `:user <handle>`, `:search <query>`, `:mentions`, `:notifs`, `:bookmarks`, and `:read <id|url>`. History navigates with `]`/`[`.

## Notifications

<p align="center">
  <img src="assets/notifications.png" alt="notifications view showing likes, replies, retweets, and follows" width="800">
</p>

Press `n` or `:notifs` to open notifications as a detail pane without losing your place in the source timeline. Likes, retweets, follows, and quotes come from the main notifications feed; replies are merged from the mentions endpoint. Type icons stay vivid for scanning, handles keep their palette color. Press `x` to expand a snippet, `Enter` to open the target tweet in a stacked detail view on top. Esc pops back to the notifications list; Esc again pops back to the source timeline.

<p align="center">
  <img src="assets/notifications-detail.png" alt="notifications with split detail pane showing a threaded conversation" width="800">
</p>

Unread badge (`Nn`) appears in the header when on other views. Auto-refreshes at the top of the list. Read tracking is separate from tweet seen state.

## Profile view

<p align="center">
  <img src="assets/profile.png" alt="own profile showing tweets with full metrics and expanded bodies" width="800">
</p>

`p` opens the profile of whoever your cursor is on — the selected tweet's author, the notification actor, or your own profile if nothing's selected. Your own profile renders with full metrics forced visible. `:user <handle>` opens anyone's timeline. Press `R` to toggle between their tweets and replies. `V` switches between all tweets and originals only (hides replies, quotes, retweets).

## Help overlay

<p align="center">
  <img src="assets/help.png" alt="scrollable help overlay showing iconography section" width="800">
</p>

`?` opens a scrollable help overlay with every keybinding and an iconography reference for all the glyphs used in the interface. Scroll with `j`/`k`, any other key closes it.

<details>
<summary><strong>Key bindings</strong></summary>

| Key | Action |
|---|---|
| `j` / `k` / `↓` / `↑` | Move selection |
| `g` / `G` | Top / bottom |
| `Ctrl-d` / `Ctrl-u` | Half-page down / up |
| `Enter` / `l` | Open tweet into detail pane |
| `h` / `←` | Go home (source); back to source (detail) |
| `q` / `Esc` | Pop detail or quit |
| `Tab` | Swap active pane |
| `,` / `.` | Narrow / widen split |
| `:` | Command palette |
| `?` | Help overlay |
| `V` | Toggle all / originals on home feed |
| `F` | Toggle For You / Following |
| `R` | Toggle tweets / replies on user profile |
| `T` | Translate selected tweet to English (toggle) |
| `A` | Ask gemma about the selected post |
| `B` | Deep profile brief on the selected author |
| `f` | Like / unlike |
| `c` | Toggle rage filter |
| `x` | Expand / collapse tweet body |
| `X` | Inline thread replies |
| `I` | Toggle media auto-expand |
| `Z` | Toggle x-dark / x-light theme |
| `M` | Toggle metric counts |
| `N` | Toggle display names |
| `t` | Toggle relative / absolute timestamps |
| `s` | Cycle reply sort in detail pane |
| `p` | Open selected author's profile (falls back to own) |
| `P` | Open own profile in browser |
| `n` | Open notifications as a detail pane |
| `o` | Open tweet in browser (auto-likes if write-rate-limited, for the browser-reply fallback) |
| `O` | Open tweet author's profile in browser |
| `m` | Open all media (photos/GIFs/videos) in native viewer |
| `y` | Yank fixupx URL to clipboard |
| `Y` | Yank tweet JSON to clipboard |
| `r` | Reply to selected tweet (auto-likes the target on submit) |
| `Ctrl-r` | Reload source / refresh thread replies |
| `u` | Jump to next unread |
| `U` | Mark all as read |
| `]` / `[` | History forward / back |
| `W` | Changelog (release history) |
| `Ctrl-c` | Quit immediately |

</details>

## More

- **Inline media** — photos, video posters, and GIF first-frames render inside the terminal via the [kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) on Ghostty, Kitty, and WezTerm. Multiple images side-by-side. Toggle with `I`. Falls back to `▣`/`▶`/`↻` glyphs elsewhere.
- **Inline cards** — YouTube links, X Articles, generic link previews (any brand), and polls render as bordered preview cards with cover image, title, description, and metadata. `m` opens the source URL in your browser.
- **Originals mode** — `V` on home feeds hides replies, quotes, and retweets. `◇` appears in the status bar. Persists across sessions.
- **Notifications view** — press `n` or `:notifs` to browse notifications in a dedicated feed. Enter opens the target tweet or navigates to the actor's profile. Ambient whisper continues in the status bar independently.
- **Read tracking** — tweets mark as read on cursor. For You feed hides already-seen tweets and deduplicates across pages. `u` jumps to next unread.
- **Theme engine** — built-in `x-dark` (X.com brand colors layered over a Rosé Pine surface palette) and `x-light` (X.com brand over Solarized Light). Swap live with `:theme x-dark|x-light|auto` or toggle with `Z`. The choice persists across sessions. The Twitter blue, like-pink, retweet-green, and quote-purple are real X brand hex values; greys, borders, and the ribbon palette come from Rosé Pine / Solarized so the TUI sits comfortably inside those terminals.
- **Color-hashed handles** — FNV-1a hash into a per-theme 20-color palette, consistent across every mention in every tweet body.
- **Zebra striping** — alternating row backgrounds drawn from the active theme.
- **Share** — `y` copies a [fixupx](https://fixupx.com) embed URL, `o` opens in browser, `m` downloads every attachment on the selected tweet (all photos, GIFs, and video MP4s). On macOS images go to QuickLook (`qlmanage -p`) — space/Esc closes and focus returns to the terminal — while videos open in QuickTime Player via an osascript wrapper that polls for the document close and reactivates the spawning terminal, so Cmd+W alone gets you back to unrager. Linux uses `xdg-open` for everything. Cache lives under `~/.cache/unrager/media/<tweet_id>/`.
- **Configurable browser** — `config.toml` supports `{}` URL placeholder for Chromium `--app={}` kiosk mode.
- **Digital clock overlay** — optional floating clock with big block-character digits. Every element is toggleable via `[clock]` in `config.toml` (see below) — time, date, seconds, 12/24h, position, accent color, border. Set `enabled = false` to hide completely.
- **Session persistence** — source, selection, toggles, split width, feed mode, reply sort all survive restarts.

<details>
<summary><strong>CLI</strong></summary>

### Read-only (no cost, no API key)

| Command | Purpose |
|---|---|
| `unrager whoami` | Confirm which account your cookies belong to |
| `unrager doctor` | Check cookies, Ollama, and gemma4 setup |
| `unrager update` | Self-update to the latest release |
| `unrager read <id\|url>` | Fetch a single tweet |
| `unrager thread <id\|url>` | Full conversation thread |
| `unrager home [--following]` | Home timeline |
| `unrager user <@handle>` | A user's tweets |
| `unrager search "<query>"` | Live search |
| `unrager mentions [--user @h]` | Mentions feed |
| `unrager bookmarks "<query>"` | Search bookmarks |
| `unrager notifs` | Recent notifications |

All accept `-n <count>`, `--json`, `--max-pages <n>`.

### Write (requires OAuth 2.0 + credits)

| Command | Purpose |
|---|---|
| `unrager auth login` | OAuth 2.0 PKCE flow (free) |
| `unrager auth status` | Show token state |
| `unrager auth logout` | Delete cached tokens |
| `unrager tweet "<text>" [--dry-run]` | Post a tweet |
| `unrager reply <id\|url> "<text>" [--dry-run]` | Reply to a tweet |

</details>

## Setup

<details>
<summary><strong>Requirements</strong></summary>

- **macOS** (stores the cookie key in your login Keychain) or **Linux** with a Secret Service provider (`kwalletd6` on KDE, `gnome-keyring` on GNOME)
- **Chromium-family browser** logged into X — auto-detected: Vivaldi, Chrome, Chromium, Brave, Edge (all channels), Opera, Arc. Override with `UNRAGER_COOKIES_PATH`.
- **Rust 1.85+** (edition 2024) — only if building from source
- **Ollama** (optional) — for the rage filter and translation. Default model `gemma4:latest`, configurable in `filter.toml`.
- **X developer account** (optional) — only for posting. OAuth 2.0 Native App + pay-per-use credits at [console.x.com](https://console.x.com).

</details>

<details>
<summary><strong>Configuration</strong></summary>

Config paths are platform-native: Linux uses `~/.config/unrager/` + `~/.cache/unrager/`, macOS uses `~/Library/Application Support/unrager/` + `~/Library/Caches/unrager/`.

| File (Linux) | Purpose |
|---|---|
| `~/.config/unrager/config.toml` | General settings (browser command, theme, etc.) |
| `~/.config/unrager/session.json` | TUI session (source, selection, toggles) |
| `~/.config/unrager/tokens.json` | OAuth 2.0 tokens (mode `0600`) |
| `~/.config/unrager/filter.toml` | Rage filter rubric (auto-created) |
| `~/.cache/unrager/seen.db` | Read-tracking SQLite |
| `~/.cache/unrager/filter.db` | Filter verdict cache |
| `~/.cache/unrager/media/<tweet_id>/` | Downloaded attachments for `m` (external viewer) |

### Theme

```toml
[theme]
name = "auto"   # auto | x-dark | x-light
```

`auto` follows the terminal background detected at startup (OSC 11). The `Z` key and `:theme <name>` command both override and persist whatever you pick. The clock's `accent` field accepts `"auto"` (default — follows the theme accent), an ANSI color name, a 256-color index, or a `#rrggbb` hex.

### Clock

Every field has a default — omit `[clock]` entirely to get the defaults (enabled, top-right, time + date, 24h).

```toml
[clock]
enabled = true
position = "footer"        # footer | header | top_left | top_right | bottom_left | bottom_right
show_time = true
show_date = true
show_seconds = false
hour_format = "auto"       # auto | h12 | h24
date_format = "auto"       # "auto" or any chrono strftime string (e.g. "%a %d %b")
accent = "cyan"            # ANSI name, 0–255 index, or #rrggbb
border = true              # only applies to the corner overlays
```

`hour_format = "auto"` (the default) reads the OS locale via `sys-locale` — so `en_US`/`en_CA`/`en_AU`/`en_IN`/etc. see `3:15 PM`, while most of Europe/Asia see `15:15`. `date_format = "auto"` picks `%a, %b %-d` for 12h locales and `%a %-d %b` otherwise. Force either with `hour_format = "h12"` / `"h24"` or an explicit strftime string.

`footer` / `header` render the clock right-aligned inside that row — one line of text, no box, no overlay. The four corner positions render as a floating overlay with an optional rounded border.

</details>

<details>
<summary><strong>Write path setup</strong></summary>

Posting uses the official X API v2 (not cookie auth), so your account is never at risk.

1. Create a developer account at [developer.x.com](https://developer.x.com)
2. Register a Native App (PKCE, no client secret)
3. Set callback URL to `http://127.0.0.1:8765/callback`
4. **Replace the Client ID** in `src/auth/oauth.rs` (`CLIENT_ID`) with your own, then rebuild
5. Load pay-per-use credits at [console.x.com](https://console.x.com)
6. `unrager auth login` — opens browser for the OAuth flow
7. `unrager tweet "hello from unrager"`

> **Why your own Client ID?** The embedded ID is the author's personal credential. X enforces per-client rate limits and may flag traffic from many unrelated users sharing a single client. Read and TUI are unaffected — only `tweet` and `reply` go through OAuth.

</details>

## Architecture

```
Reads:   browser cookies  ->  GraphQL (same endpoints as x.com)  ->  free, unlimited
Writes:  OAuth 2.0 PKCE   ->  official X API v2                  ->  pay-per-use
Filter:  tweet text        ->  local Ollama                       ->  HIDE/KEEP -> SQLite cache
Media:   CDN fetch         ->  downscale 400px                    ->  kitty graphics transmit
```

<details>
<summary><strong>Security model</strong></summary>

1. **Browser cookies** — read at runtime, decrypted in memory using the OS credential store (macOS Keychain, Linux Secret Service), never written to disk or logged
2. **OAuth tokens** — `~/.config/unrager/tokens.json` mode `0600`, atomic writes
3. **Client ID** — embedded `const`, safe per PKCE design (no client secret)
4. **Filter** — runs entirely locally, tweet text never leaves your machine

</details>

## Contributing

```sh
cargo fmt --all
cargo clippy --all-targets -- -D warnings
cargo test
```

## Legal

Not affiliated with X Corp. Uses X's web GraphQL endpoints the same way the web client does. Do not use this to scrape at scale or run bots.
