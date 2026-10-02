<p align="center">
  <h1 align="center">unrager</h1>
  <p align="center">
    Take the rage out of your x.com timeline.<br>
    A model on your own computer reads every post first and quietly removes the rage-bait.
  </p>
  <p align="center">
    <a href="https://crates.io/crates/unrager"><img src="https://img.shields.io/crates/v/unrager?style=flat-square&label=crates.io&logo=rust&color=orange" alt="crates.io"></a>
    <a href="https://midgarcorp.cc/unrager/"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Funrager.com%2Fapi%2Fbadge&style=flat-square&cacheSeconds=300" alt="installs"></a>
    <a href="https://github.com/guitaripod/unrager/actions"><img src="https://img.shields.io/github/actions/workflow/status/guitaripod/unrager/ci.yml?branch=master&style=flat-square&label=ci" alt="CI"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="GPL-3.0 License"></a>
  </p>
</p>

<p align="center">
  <img src="assets/extension.png" alt="An x.com Home timeline with the unrager extension and Show hidden posts on: four calm posts, two rage-bait posts dimmed, each labelled with the rule that hid it and a Show this post button, and the toolbar badge counting them" width="520">
</p>

unrager is a browser extension for the x.com you already use. As X loads your Home timeline, a language model running on your computer reads each post and hides the ones that match your rules: the outrage, the ratio bait, the doom and the engagement farming. You keep X's own app, your account and every feature; you lose the posts that exist to make you angry.

It isn't perfect, and it shows its work. Tested on 1,000 real posts from one person's feed, against their own rules, the default model took out about two in three rage posts and hid about one good post in twenty. Every post it hides is one switch away, labelled with the rule that caught it, and one click brings it back for good. The model is small on purpose: 2.5 GB, it runs on an ordinary laptop, and bigger ones hide more of what you wanted to see (a 27B model hid one good post in four).

Nothing leaves your computer. The extension talks to unrager on `localhost`, unrager talks to your model, and the model never sees anything but the post it's judging. It works with [Ollama](https://ollama.com) out of the box, or with any server that speaks the OpenAI chat API: LM Studio, vLLM, llama.cpp, SGLang, llama-swap.

## Install

You need a Chromium browser (Chrome, Brave, Edge, Vivaldi or Arc) on macOS or Linux, and a model to run.

**1. Get a model.** The simplest is [Ollama](https://ollama.com): install it, then

```sh
ollama pull qwen3:4b-instruct
```

Already running LM Studio, vLLM, llama.cpp or SGLang? Skip this; step 2 finds it. See [Using another model server](#using-another-model-server).

**2. Install unrager.**

```sh
curl -fsSL https://unrager.com/install.sh | bash
```

The installer runs `unrager setup`, which checks that your model answers, starts unrager in the background (a systemd user service on Linux, a launch agent on macOS, so it comes back after a restart), and unpacks the extension. Run `unrager setup` again any time; it's safe to repeat.

**3. Add the extension to your browser**, once:

1. open `chrome://extensions` (it works in every Chromium browser)
2. turn on **Developer mode**
3. click **Load unpacked**, press <kbd>Ctrl</kbd>+<kbd>L</kbd> (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>G</kbd> on macOS) and paste the folder `unrager setup` printed:
   - Linux: `~/.local/share/unrager/browser-extension`
   - macOS: `~/Library/Application Support/unrager/browser-extension`

Open x.com. Posts that match your rules never show up in For you and Following: the timeline fills in from the top as your model reads each new post, which takes a moment per page, and the unrager icon counts the ones it hid.

<details>
<summary><strong>Other ways to install</strong></summary>

With Rust 1.85 or newer:

```sh
cargo install unrager
unrager setup
```

Leaner builds without the extension's server, for the terminal client or scripts only:

```sh
UNRAGER_FLAVOR=tui curl -fsSL https://unrager.com/install.sh | bash   # terminal client + CLI
UNRAGER_FLAVOR=cli curl -fsSL https://unrager.com/install.sh | bash   # CLI only
cargo install unrager --no-default-features --features tui            # same, from source
```

The installer also takes `UNRAGER_INSTALL_DIR` (default `~/.local/bin`) and `UNRAGER_NO_SETUP=1` to skip running `unrager setup`. Windows isn't supported; WSL2 runs the terminal client.

</details>

### Updating

```sh
unrager update
```

downloads the new release, restarts the background server on it and refreshes the unpacked extension. The extension's popup then offers **Reload extension** to finish; click it (or ↻ on its card at `chrome://extensions`). If you installed with cargo, `cargo install unrager --force && unrager setup` does the same.

### Uninstalling

```sh
unrager setup --uninstall     # stops the background server, removes the unpacked extension
curl -fsSL https://unrager.com/install.sh | bash -s -- --uninstall
```

then remove the unrager card from `chrome://extensions`.

## Using it

<p align="center">
  <img src="assets/popup.png" alt="The unrager popup: 12 posts hidden and 148 checked on this tab, the pause and show-hidden switches, how strict the filter is, and the editable list of topics with how many posts each one hid" width="340">
</p>

Click the unrager icon for its popup:

- **Status** says whether the filter is working on this tab, how many posts it hid, and, when something's wrong, what to run to fix it (unrager isn't running, the model isn't answering, a tab needs a reload, an update needs finishing).
- **Pause filtering** shows X exactly as it is until you switch it back on.
- **Show hidden posts** brings hidden posts back, dimmed and labelled with the rule that hid each one, so you can check the model's judgment. **Show this post** keeps one on screen for good.
- **What gets hidden** is your rules: how strict the filter is, and the topics to add, edit or remove, each with how many posts it hid since the rules last changed. Save, and open x.com tabs are checked again under the new rules right away; what's hidden stays hidden until then.
- **Settings** points the extension at unrager on another computer, such as the desktop with the GPU (see [Running the model on another computer](#running-the-model-on-another-computer)).

Right-click any post on your Home timeline for **Hide this post** or **Show this post**. unrager remembers the choice: it outranks the model in the extension, the terminal client and the iPhone app, and survives rule changes.

On For you, every post gets a **Not interested** button, a small frown next to X's Grok button. One click does what *Not interested in this post* in the post's ⋯ menu does, without the menu: X shows its usual confirmation, with Undo and **Show fewer posts from** that account.

The toolbar badge shows how many posts were hidden on the current tab, `off` while paused, `!` when posts can't be checked and `↑` when the extension and unrager are different versions (open the popup to finish updating).

Only your Home timeline (For you and Following) is filtered. Profiles, search, threads and notifications are always shown in full: the filter exists for the feed you didn't choose, not for the places you went looking. Your own posts, and the conversations you've replied in, are never hidden. A reply to a hidden post is hidden with it, so no reply is left answering nothing.

## Your rules

The rules live in `filter.toml` (Linux `~/.config/unrager/`, macOS `~/Library/Application Support/unrager/`), which the popup edits for you. A post is hidden when one of the topics *is the point* of it, not when it only mentions one in passing:

```toml
drop_topics = [
    "american electoral politics, presidents, congress, partisan fights",
    "war, military conflict, battlefield footage, casualty counts",
    "economic fearmongering: tariff panic, inflation doom, market-crash prophecies",
    "crypto and NFT shilling, pump-and-dump hype, rug-pull drama",
    # add your own
]
extra_guidance = "KEEP technical, scientific, art, music, sports, personal-life, and humor tweets that only mention these topics in passing."
strictness = "balanced"
```

`strictness` sets how readily a post goes:

- `"balanced"`, the default: the topics, plus what you'd mute on sight: subtweets, ratio bait, "RT if you agree" engagement farming, and outrage with no information in it. Spicy opinions and sharp critique stay as long as there's something there besides an invitation to be angry, and so does anything the model isn't sure about, like a short reply or a post that's only a photo.
- `"relaxed"`: only posts clearly about one of the topics.
- `"strict"`: also posts by people known for a topic, and anything the model isn't sure about.

Your own posts are never hidden. The model names the rule behind each post it hides.

Each verdict is cached per post, so scrolling back is instant and nothing is judged twice. Changing the rules, the strictness or the model throws the cache out automatically.

### Checking your model

unrager treats a good post hidden as a worse mistake than a rage post let through: you can see the rage post and scroll past it, but you never learn about the good one. `unrager eval` measures both. Your model judges about 200 made-up posts labelled against the default rules, and unrager prints how many good posts it hid and how much rage it caught, each with its 95% range, and whether that's good enough to filter with:

```sh
unrager eval                          # your model, your strictness
unrager eval --strictness strict      # compare a strictness level
unrager eval --model qwen3:4b-instruct --mistakes   # try another model, list what it got wrong
```

Made-up posts only go so far. To measure on your own feed, label some of your posts in a file, one JSON object per line: `{"expect": "hide", "text": "@handle (Name): the post"}`, where `expect` is `hide`, `keep` or `either` (for posts reasonable people would disagree on). Optionally, `rule` (the number or numbers of the rules a hide breaks) checks the reason each hide names, `source` and `lang` split the results by timeline and language, and `about` is a note `--mistakes` prints. `unrager eval --posts that-file.jsonl` then judges them against your own rules.

To compare two models, save a run and judge the same posts with the other one. unrager counts the posts only one of them hid and says whether the difference could be chance:

```sh
unrager eval --posts mine.jsonl --save today.jsonl
unrager eval --posts mine.jsonl --model another-model --against today.jsonl --repeat 3
```

`--repeat` judges every post several times and scores the majority, since a few verdicts change between runs even at temperature 0. When the model server reports token probabilities (llama.cpp, vLLM, SGLang, Ollama 0.12.11 and later), unrager also shows how much rage the model would catch at 2% and 5% of good posts hidden, which compares models fairly even when one hides more readily than the other.

## Using another model server

Any server with an OpenAI-compatible `/v1/chat/completions` endpoint works. Set it under `[llm]` in `filter.toml`:

```toml
[llm]
backend = "openai"
host = "http://localhost:1234"   # LM Studio 1234, vLLM 8000, llama-server 8080, SGLang 30000
model = "qwen3-8b"               # an id from the server's /v1/models
timeout_seconds = 120            # a model that has to load first is slow to answer
# api_key = "..."                # only if the server was started with one
```

If the model you configured isn't reachable, `unrager setup` and `unrager doctor` look for servers on those usual ports and print the lines to paste. Both also send the model one real request, since a server can list a model it can't actually run.

The filter can run on its own model. A small one judges posts as well as a big one (on unrager's tests Qwen3 4B hid fewer good posts than a 27B model), loads in a couple of seconds and can stay loaded, so new posts never wait on a model that's still starting. To keep a bigger model for ask, brief and translate in the terminal client, name both:

```toml
[llm]
model = "qwen3-27b"          # ask, brief, translate
filter_model = "qwen3-4b"    # judging posts
```

Any instruction-tuned model that can answer HIDE or KEEP will do; small ones (2–12B) are plenty, and faster is better, since new posts wait for their verdict. For Ollama, the default is:

```toml
[llm]
backend = "ollama"
host = "http://localhost:11434"
model = "qwen3:4b-instruct"
timeout_seconds = 20
keep_alive = "30m"   # how long Ollama keeps the model loaded; "10s" frees the GPU soon after you stop scrolling
```

### Running the model on another computer

Run unrager on the machine with the GPU and let it listen beyond `localhost`, ideally only on a private network like Tailscale (unrager has no login of its own):

```sh
unrager setup --bind 0.0.0.0:7777
```

Then, in the extension's popup on the other computer, open **Settings** and enter that machine's address, e.g. `http://100.101.102.103:7777`. The browser asks once for permission to reach it.

## Troubleshooting

`unrager doctor` checks everything the extension needs (the model, the background server, the unpacked extension) and prints a fix for anything that's wrong. The popup covers the rest from the browser's side.

- **Posts aren't being hidden.** Open the popup. If it says *Reload this tab*, the tab was open before the extension was added or updated. If the badge shows `!`, unrager or the model isn't answering; `unrager doctor` says which.
- **Something was hidden that shouldn't have been.** Turn on *Show hidden posts*: each hidden post says which rule hid it, and *Show this post* brings one back for good. When one rule hides too much (the popup counts what each one hid), sharpen it or add a line to *Anything else the model should know*; when everything does, set *How strict* to Relaxed. Small models misjudge more; a bigger or better-tuned one is the other lever.
- **Logs.** The background server logs to `journalctl --user -u unrager-serve` (Linux) or `~/Library/Logs/unrager-serve.log` (macOS), and every unrager process writes to `~/.cache/unrager/unrager.log.<date>` (macOS: `~/Library/Caches/unrager/`), keeping the 14 most recent. On x.com, `window.__unrager_status()` in the page console shows what the extension did on that tab.

If the model isn't answering, X keeps working as usual: unrager fails open. A new post waits at most two and a half seconds for its verdict and then shows anyway, a failed check is never remembered, and those posts are asked about again shortly.

## Privacy

- The extension reads only the Home timeline responses X already sends your browser. It requests nothing extra from X and changes nothing X sends; it only hides posts on your screen. The **Not interested** button clicks X's own menu item for you, so what X hears is exactly what it would from the menu.
- Post text goes from the extension to unrager on your computer, and from unrager to your model. There's no account, no telemetry, and no server of ours in the loop.
- The background server `unrager setup` installs runs in filter-only mode: it never reads your X login and never talks to X.
- The server answers only the extension and the iPhone app. Requests from web pages are refused, so a site you visit can't use it through your browser.
- The one optional exception is `[about] community_cache` (off by default; see [Country flags](#configuration)): with it on, `unrager serve` sends the handles of the authors on screen to the X-Posed community cache to look up their country.

## Also in the box

The extension is the main way to use unrager, but it grew out of a terminal client for X, and that's all still here: the same filter in a keyboard-driven timeline, an iPhone app for when you're away from the desk, and a CLI.

### The terminal client

<p align="center">
  <img src="assets/terminal.png" alt="unrager's terminal client: the Following timeline in a terminal, twelve posts filtered out (−12 in the top bar)" width="600">
</p>

Run `unrager` for a Twitter/X client in your terminal: your Home timeline with the rage filter, threads in a split pane, inline images on kitty-graphics terminals (Ghostty, Kitty, WezTerm), notifications, profiles, search, and a local model that translates (`T`), explains (`A`) and briefs you on an account (`B`). Every text input is a small Vim editor. `unrager demo` tries it against a bundled offline feed, no X login needed.

It reads through the same GraphQL endpoints x.com uses, with the login cookies of your Chromium browser (Vivaldi, Chrome, Brave, Edge, Opera, Arc), decrypted in memory with your OS credential store and never written anywhere. If you're logged in with more than one browser, pin one with `cookie_browser = "Vivaldi"` in `config.toml` (or `UNRAGER_BROWSER`). Posting goes through the official X API with your own OAuth client; see [Posting](#posting).

<details>
<summary><strong>Reading threads</strong></summary>

`Enter` opens a tweet into a split detail pane. The focal tweet and all its replies form one scrollable list. Push deeper into any reply with `Enter`, pop back with `Esc`. Press `s` to cycle reply sort order — newest, likes, replies, retweets, views — it persists across sessions. `X` expands inline thread replies without leaving the current view.

The left pane stays live. `Tab` swaps focus between panes, `,`/`.` adjusts the split width.

</details>

<details>
<summary><strong>Composing (Vim-mode everywhere)</strong></summary>

Every text input in the TUI — reply (`r`), ask input (`A`), command palette (`:`) — is a miniature Vim editor. Insert/Normal modes, `hjkl` motion, `w`/`b` word jumps, `dd`/`dw`, counts, `^`/`$`. The status line at the bottom of each pane shows `INSERT` or `NORMAL` and the live character counter (`24/280`).

Submit (`Enter` in insert mode) doesn't post over the X GraphQL write endpoint — that path errors out on most accounts in a way unrager can't route around. Instead, the composed text is copied to your clipboard and the parent tweet opens in your browser. Paste, send, done. Press `Esc` twice (Insert → Normal → exit) to close the editor — your draft is kept in memory until you leave the parent tweet's detail pane, so an accidental close doesn't lose your text.

Submitting a reply with `r` auto-likes the tweet you're replying to — that happens the moment you hit Enter, before the browser opens. The like is skipped if it's your own tweet, already liked, or X is write-rate-limiting you.

</details>

<details>
<summary><strong>Search, translate and ask</strong></summary>

`:search nvidia` pulls live results in every language. Press `T` on any tweet to translate it to English with your model; `T` again reverts. Translations live in memory only.

Press `A` on any tweet to open an ask pane on the same model. The post is pinned to the top, a chip row exposes preset prompts (`1` Explain, `2` Replies, `3` Counter, `4` ELI5, `5` Entities) that fire with a single keystroke when the input is empty, and the reply streams inline. On Ollama with a vision model like gemma4, up to four photos on the post are attached to the first turn. Opened from a thread, the loaded replies come along as context, so `2 Replies` actually summarizes the thread. `B` writes a short brief on the selected author from their recent timeline.

The command palette supports `:home`, `:user <handle>`, `:search <query>`, `:mentions`, `:notifs`, `:bookmarks`, and `:read <id|url>`. History navigates with `]`/`[`.

</details>

<details>
<summary><strong>Notifications and profiles</strong></summary>

Press `n` or `:notifs` to open notifications as a detail pane without losing your place. Likes, retweets, follows and quotes come from the notifications feed; replies are merged from mentions. `x` expands a snippet, `Enter` opens the target tweet on top, `Esc` pops back. An unread badge (`Nn`) appears in the header on other views.

`p` opens the profile of whoever your cursor is on — the selected tweet's author, the notification actor, or your own profile. The header pins an avatar, name, handle and follower counts, plus what X's about-profile lookup exposes: country flag and "based in", where the account was created, join date, verification date and past username changes. The country flag also rides next to the handle in every feed row. Your own profile renders with full metrics and an analytics block. `R` toggles tweets and replies, `<space> o` originals only.

</details>

<details>
<summary><strong>Key bindings</strong></summary>

`?` opens a scrollable help overlay with every binding and the meaning of every glyph.

| Key | Action |
|---|---|
| `j` / `k` / `↓` / `↑` | Move selection |
| `g` / `G` | Top / bottom |
| `Ctrl-d` / `Ctrl-u` | Half-page down / up |
| `Enter` / `l` | Open tweet into detail pane |
| `q` / `Esc` | Pop detail (or quit on home:following) |
| `Tab` | Swap active pane |
| `,` / `.` | Narrow / widen split |
| `:` | Command palette |
| `?` | Help overlay |
| `<space>` | Leader — which-key popup for session toggles |
| `<space> o` | Toggle all / originals on home feed |
| `<space> f` | Toggle For You / Following |
| `<space> m` | Toggle metric counts |
| `<space> n` | Toggle display names |
| `<space> d` | Toggle relative / absolute timestamps |
| `<space> t` | Cycle x-dark / x-light theme |
| `<space> i` | Toggle media auto-expand |
| `<space> a` | Toggle author-avatar chips in feeds (kitty terminals only) |
| `<space> r` | Toggle rage filter |
| `R` | Toggle tweets / replies on user profile |
| `T` | Translate selected tweet to English (toggle) |
| `A` | Ask the model about the selected post |
| `B` | Deep profile brief on the selected author |
| `f` | Like / unlike |
| `x` | Expand / collapse tweet body |
| `X` | Inline thread replies |
| `s` | Cycle reply sort in detail pane |
| `p` | Open selected author's profile (falls back to own) |
| `P` | Open own profile in browser |
| `n` | Open notifications as a detail pane |
| `o` | Open tweet in browser (auto-likes, except on your own tweets) |
| `O` | Open tweet author's profile in browser |
| `m` | Open all media (photos/GIFs/videos) in native viewer |
| `M` | Open URLs in tweet body (music links auto-routed through song.link) |
| `S` | Screenshot composer, default action save to `~/.cache/unrager/screenshots/` |
| `C` | Screenshot composer, default action copy to clipboard |
| `y` | Yank fixupx URL to clipboard |
| `Y` | Yank tweet JSON to clipboard |
| `r` | Reply to selected tweet — `Enter` copies text + opens the parent in browser, auto-likes the target (skipped on own tweets) |
| `c` | Compose a new tweet — `Enter` copies text + opens X's composer in browser |
| `Ctrl-r` | Reload source / refresh thread replies |
| `u` | Jump to next unread |
| `U` | Mark all as read |
| `]` / `[` | History forward / back |
| `W` | Changelog (release history) |
| `Ctrl-c` | Quit immediately |

</details>

<details>
<summary><strong>Everything else</strong></summary>

- **Inline media** — photos, video posters, and GIF first-frames render inside the terminal via the [kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) on Ghostty, Kitty, and WezTerm. Multiple images side-by-side. Toggle with `I`. Falls back to `▣`/`▶`/`↻` glyphs elsewhere.
- **Author avatars** — every feed row, detail focal, reply, and inline thread carries a square kitty-graphics chip of the poster's avatar; profile headers pin a larger one. Avatars cache at `~/.cache/unrager/avatars/` (LRU-pruned to 50 MB, self-invalidating since X rotates the URL on every photo change). Toggle feed chips with `<space> a`.
- **Inline cards** — YouTube links, X Articles, X Broadcasts (with a red `● LIVE` badge while running), generic link previews, and polls render as bordered preview cards. `m` opens the source URL in your browser.
- **Originals mode** — `V` on home feeds hides replies, quotes, and retweets. `◇` appears in the status bar. Persists across sessions.
- **Read tracking** — tweets mark as read on cursor. For You hides already-seen tweets and deduplicates across pages. `u` jumps to next unread.
- **Theme engine** — built-in `x-dark` (X brand colors over a Rosé Pine surface palette) and `x-light` (X brand over Solarized Light). Swap live with `:theme x-dark|x-light|auto` or toggle with `Z`; the choice persists.
- **Color-hashed handles** — FNV-1a hash into a per-theme 20-color palette, consistent across every mention.
- **Share** — `y` copies a [fixupx](https://fixupx.com) embed URL, `o` opens in browser, `m` downloads every attachment on the selected tweet and opens it (QuickLook / QuickTime on macOS, `xdg-open` on Linux). Downloads live under `~/.cache/unrager/media/<tweet_id>/`, trimmed to 512 MB (posts downloaded longest ago go first) when the terminal client starts.
- **Postcard** — `S` (or `C`) rasterizes the focal tweet to a PNG with one of six themes (`glass`, `synthwave`, `cutout`, `moss`, `blueprint`, `arcade`), "match TUI", or a custom two-color theme. `s` saves to `~/.cache/unrager/screenshots/`, `y` copies. `T` captures the whole reply chain as one tall image; `n` toggles display names, `m` the metrics row. Color emoji render as full-color [Twemoji](https://github.com/jdecked/twemoji) images (the newest set is resolved at runtime and cached under `~/.cache/unrager/emoji/`), at 2× density.
- **Configurable browser** — `config.toml` supports a `{}` URL placeholder for Chromium `--app={}` kiosk mode.
- **Digital clock overlay** — optional floating clock with big block-character digits, configured under `[clock]` in `config.toml`.
- **Session persistence** — source, selection, toggles, split width, feed mode, reply sort all survive restarts.
- **Feed buffer** — Home is served from a small local SQLite buffer that a background worker keeps fresh and pre-classified, so the terminal client and the iPhone app open instantly. See [Configuration](#configuration).

</details>

### The iPhone app

<p align="center">
  <img src="assets/iphone.png" alt="The unrager iPhone app, three screens with made-up posts: the For You feed with country flags and a repost, the list of hidden posts each labelled with the rule that hid it and a Show button, and an Ask answer from your own model" width="760">
</p>

The extension can't reach X's own iPhone app, so there's a native one: [`ios/`](ios/) (UIKit, iOS 26), a thin client over the API `unrager serve` exposes. It's the same idea on a phone: Home opens instantly from the server's buffer, the rage filter judges what you'd otherwise scroll past, and your own model answers when you ask. It uses your X session, so it isn't a store app; you build it once yourself, as below.

- **Feeds and threads.** For you, Following, Mentions, Bookmarks and search, with photos, inline video, alt text and quoted posts. A repost shows the original with "Kit Wren reposted", a profile's pinned post comes first, links to x.com open in the app, and every author carries a country flag. Rows are one VoiceOver stop with actions and follow Dynamic Type up to the largest sizes.
- **The filter, with receipts.** Posts the rage filter hides are listed with the rule that caught each one and a **Show** button, and the rules and strictness are editable in the app. Your own overrule outranks the model everywhere.
- **Your model, on tap.** Ask, Brief and Translate stream from the model on your server and can be stopped, retried and read as they arrive. A post or a whole thread exports as a postcard image.
- **Profiles.** Bio, location, website and join date, follower counts, who quoted a post, and Mute and Block. Suspended, protected and deleted accounts say so instead of failing.
- **Notifications.** Activity grouped under New and by day, with a digest of what the unread part added up to, filter chips for mentions, likes, reposts and follows, Follow back on a new follower, a calm unread badge, in-app toasts and optional banners (there is no push server, so banners come from the foreground poller and iOS background refresh), and a read marker that follows you across devices.
- **Writing.** Post, reply and quote with drafts kept, delete your own posts, like, repost and bookmark.

Country flags are what X's "About this account" says, asked one author at a time. If X rate-limits that lookup, or you'd rather not wait on it, see [Country flags](#configuration).

#### Put it on your iPhone

It takes about ten minutes. You need the computer that runs unrager (signed in to x.com in a Chromium browser), [Tailscale](https://tailscale.com) on it and on your phone (free), and, for building once, a Mac with Xcode 26 and `brew install xcodegen`, plus an iPhone on iOS 26 and any Apple ID: a free one works.

**1. On the computer that runs unrager**, start the full server. It prints the address the app needs:

```sh
unrager setup --apps --bind 0.0.0.0:7777
# ✓ iphone      in the app, open Settings → Server and enter http://100.64.0.9:7777
```

unrager has no login of its own, so keep that to a private network like Tailscale.

**2. On the Mac**, with Xcode signed in to your Apple ID (Xcode > Settings > Accounts) and the phone plugged in, unlocked and trusted, with Developer Mode on (Settings > Privacy & Security):

```sh
git clone https://github.com/guitaripod/unrager
cd unrager/ios
./scripts/install.sh
```

The script finds your phone and signing team, asks for the server address, builds, installs and opens the app.

**3. On the phone**, trust yourself if it asks (Settings > General > VPN & Device Management), open Unrager, allow the local network, and if Home is empty enter the address under Settings > Server.

To update, `git pull` and run the script again; a free Apple ID's build stops opening after 7 days and is renewed the same way. [`ios/README.md`](ios/README.md) has every step in detail, what each error means, and how to do it by hand in Xcode.

### The CLI

<details>
<summary><strong>Commands</strong></summary>

| Command | Purpose |
|---|---|
| `unrager setup` | Check the model, run unrager in the background, unpack the extension (`--apps` for the iPhone app, `--bind`, `--no-service`, `--uninstall`) |
| `unrager doctor` | Check the model, the background server, the extension and your X login |
| `unrager eval` | Measure how well your model filters (`--strictness`, `--model`, `--mistakes`, `--posts` for your own labelled posts, `--save`/`--against` to compare runs, `--repeat`) |
| `unrager update` | Update to the latest release (restarts the server and refreshes the extension) |
| `unrager serve` | Run the server by hand (`--filter-only` for just the extension, `--bind`) |
| `unrager whoami` | Confirm which account your cookies belong to |
| `unrager read <id\|url>` | Fetch a single tweet |
| `unrager thread <id\|url>` | Full conversation thread |
| `unrager home [--following]` | Home timeline |
| `unrager user <@handle>` | A user's tweets |
| `unrager search "<query>"` | Live search |
| `unrager mentions [--user @h]` | Mentions feed |
| `unrager bookmarks "<query>"` | Search bookmarks |
| `unrager notifs` | Recent notifications |

The read commands accept `-n <count>`, `--json`, `--max-pages <n>`.

| Command (official X API, pay-per-use) | Purpose |
|---|---|
| `unrager auth login` | OAuth 2.0 PKCE flow (free) |
| `unrager auth status` | Show token state |
| `unrager auth logout` | Delete cached tokens |
| `unrager tweet "<text>" [--dry-run]` | Post a tweet |
| `unrager reply <id\|url> "<text>" [--dry-run]` | Reply to a tweet |

</details>

## Configuration

<details>
<summary><strong>Files</strong></summary>

Paths are platform-native: Linux uses `~/.config/unrager/`, `~/.cache/unrager/` and `~/.local/share/unrager/`; macOS uses `~/Library/Application Support/unrager/` and `~/Library/Caches/unrager/`.

| File (Linux) | Purpose |
|---|---|
| `~/.config/unrager/filter.toml` | Your rules and the model to use (auto-created) |
| `~/.config/unrager/config.toml` | General settings (browser command, theme, clock, feed buffer) |
| `~/.config/unrager/session.json` | Terminal client session (source, selection, toggles) |
| `~/.config/unrager/tokens.json` | OAuth 2.0 tokens (mode `0600`) |
| `~/.local/share/unrager/browser-extension/` | The unpacked extension `unrager setup` writes |
| `~/.config/systemd/user/unrager-serve.service` | The background server `unrager setup` installs (macOS: `~/Library/LaunchAgents/com.unrager.serve.plist`) |
| `~/.cache/unrager/filter.db` | Verdict cache (pruned after 7 days) |
| `~/.cache/unrager/seen.db` | Read-tracking SQLite |
| `~/.cache/unrager/feed.db` | Materialized Home buffer for the terminal client and the iPhone app (`feed.db.writer.lock` guards the single writer) |
| `~/.cache/unrager/about.db` | Country flag and about-profile cache, shared by the terminal client and `unrager serve` |
| `~/.cache/unrager/media/<tweet_id>/` | Downloaded attachments for `m` (external viewer; pruned to 512 MB) |
| `~/.cache/unrager/screenshots/` | PNG screenshots written by `S` |
| `~/.cache/unrager/avatars/<sha256>.bin` | Author-avatar disk cache (LRU-pruned to 50 MB) |
| `~/.cache/unrager/emoji/<stem>.png` | Color emoji PNGs (Twemoji) composited into screenshots |
| `~/.cache/unrager/mordor-user-<hash>.opus` | Sliced Mordor loop (generated from `[sound] source`) |
| `~/.cache/unrager/unrager.log.<date>` | Daily log (the 14 most recent are kept) |

</details>

<details>
<summary><strong>Feed buffer</strong></summary>

The terminal client and the iPhone app serve Home (For You + Following) from a small local SQLite buffer that a background worker keeps fresh and pre-classified, so they open instantly instead of fetching X live. The worker runs inside a full `unrager serve` or, when none is running, inside the terminal client; whichever process wins `feed.db.writer.lock` does the ingest and the rest read the shared buffer. It fills toward the cap in the background, then parks (no fetching, no GPU) until a client opens the feed. Every client shows an "updated Nm ago" indicator backed by `GET /api/feed/status`. The extension doesn't use the buffer; it filters what x.com loads. Override in `config.toml`:

```toml
[feed]
buffer_cap = 500        # tweets kept per feed (For You / Following)
active_poll_secs = 180  # poll cadence while the app is open
recent_poll_secs = 1200 # cadence while filling the buffer in the background
```

</details>

<details>
<summary><strong>Country flags</strong></summary>

Flags come from X's own "About this account" lookup, one author at a time on your X session, which X rate-limits. `unrager serve` can ask the community cache behind the [X-Posed](https://github.com/xaitax/x-account-location-device) extension first: one batched request returns the country, device and account age of every author on screen, and flags keep loading while X refuses the query. It is off by default because each lookup tells that third-party service which handles you are looking at (nothing else, and nothing is ever contributed back). The terminal client always asks X.

```toml
[about]
community_cache = true
```

</details>

<details>
<summary><strong>Theme</strong></summary>

```toml
[theme]
name = "auto"   # auto | x-dark | x-light
```

`auto` follows the terminal background detected at startup (OSC 11). The `Z` key and `:theme <name>` command both override and persist whatever you pick.

The Mordor wallpaper and fiery accents on the For You feed require *both* a dark theme and a dark terminal background. Terminal-background detection is done once at startup; if you switch your system between light and dark while unrager is running, re-run `:theme x-light` / `:theme x-dark` or restart to re-detect.

</details>

<details>
<summary><strong>Mordor-mode audio</strong></summary>

Opt-in: set `UNRAGER_SOUND=1` and configure an audio file — unrager then plays it on loop while Mordor mode is active and stops the instant you leave For You or switch to a light theme. There is no built-in fallback. No audio libraries are linked into the binary — playback shells out to whichever of `ffplay`, `mpv`, `paplay`, `pw-play`, `afplay`, or `aplay` is on your `$PATH`.

```toml
[sound]
source = "/path/to/your/audio.flac"   # any format ffmpeg can read
start = "0:55"           # MM:SS, HH:MM:SS, or raw seconds (default: 0)
end = "1:40"             # same formats — or use `duration` instead
duration = 45            # seconds after `start` — ignored if `end` is set
fade_ms = 50             # fade-in/out at loop boundaries (default: 50)
volume = 0.5             # 0.0–1.0 pre-master gain (default: 0.5)
```

On next launch unrager slices, fades, downmixes, and encodes the file into a small Opus loop cached under `~/.cache/unrager/mordor-user-<hash>.opus` (requires `ffmpeg` for the one-time encode). The cache key hashes the source path, its mtime and every knob above. Alternatively drop a pre-encoded file at `~/.config/unrager/mordor-sound.{opus,ogg,oga,flac,mp3,wav}`; it's used raw. `tail -f ~/.cache/unrager/unrager.log.$(date +%Y-%m-%d) | grep -i mordor` shows what was picked up.

</details>

<details>
<summary><strong>Clock</strong></summary>

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

`hour_format = "auto"` reads the OS locale, so `en_US` sees `3:15 PM` while most of Europe and Asia see `15:15`. `footer` / `header` render the clock right-aligned inside that row; the four corner positions render as a floating overlay.

</details>

<details>
<summary><strong>Query IDs</strong></summary>

The terminal client and the iPhone app's server call X's GraphQL operations by query IDs that X rotates when it deploys. unrager scrapes them from X's web bundle, caches them, and falls back to a built-in table; `unrager doctor` reports how fresh they are. If X changes its bundle faster than a release, override them in `config.toml`:

```toml
[query_ids]
HomeTimeline = "abc123"
```

</details>

## Posting

Posting from the terminal client's CLI uses the official X API v2 (not cookie auth) with your own OAuth 2.0 PKCE client, so posts are attributed to your developer client and your read cookies are never used for writes.

```sh
unrager auth setup
```

walks you through it: it prints the X developer-portal URL, waits for you to register a Native App (PKCE, callback `http://127.0.0.1:8765/callback`), stores the Client ID in `config.toml` (or use `UNRAGER_X_CLIENT_ID`), and runs `unrager auth login`. Load pay-per-use credits at [console.x.com](https://console.x.com), then `unrager tweet "hello from unrager"`.

## How it fits together

```
Extension:  x.com timeline response  ->  extension  ->  unrager (localhost:7777)  ->  your model  ->  HIDE / KEEP  ->  hidden on screen
Terminal:   browser cookies  ->  X's GraphQL (same endpoints as x.com)  ->  filter  ->  terminal
iPhone:     iPhone app  ->  unrager serve  ->  X's GraphQL  ->  filter
Posting:    OAuth 2.0 PKCE  ->  official X API v2
```

Verdicts are cached in SQLite per post and per rules-and-model, and shared by every part: a post the extension already judged is instant in the terminal client, and the other way around.

## Contributing

```sh
cargo fmt --all
cargo clippy --all-targets -- -D warnings
cargo test
```

The iPhone app's Swift package has its own tests: `cd UnragerKit && swift test` (the app's own run with `xcodebuild test` in `ios/`, on macOS).

The extension is plain JavaScript in [`browser/extension/`](browser/extension/); `unrager setup` embeds that folder into the binary, so load it unpacked from there while working on it.

## Legal

Not affiliated with X Corp. The extension only reads what x.com already sends your browser; the terminal client uses X's web GraphQL endpoints the same way the web client does. Don't use it to scrape at scale or run bots.

Emoji graphics composited into postcard screenshots are from [Twemoji](https://github.com/jdecked/twemoji) (the maintained `jdecked/twemoji` fork), licensed [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/).
