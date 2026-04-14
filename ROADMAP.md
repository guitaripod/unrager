# Roadmap

## Done

- [x] Cookie-auth reads (home, user, search, mentions, bookmarks, thread, read)
- [x] OAuth 2.0 PKCE write path (tweet, reply, media upload)
- [x] Interactive TUI (split detail, command palette, history, session persistence)
- [x] Local-LLM rage filter (gemma4 via Ollama, SQLite cache, editable rubric)
- [x] Inline media via kitty graphics (Ghostty, Kitty, WezTerm)
- [x] Color-hashed @handles, zebra rows, theme-aware rendering
- [x] **macOS support** — Security.framework Keychain backend, same cookie pipeline as Linux
- [x] **Prebuilt binaries** for x86_64/aarch64 on both Darwin and Linux-gnu
- [x] **One-liner installer** — `curl -fsSL .../install.sh | bash`, SHA256-verified, quarantine-stripped on macOS, PATH hints
- [x] **Validated-release gate** — every tag fans out to 4 build targets, 6 Linux distros (Debian 12 / Ubuntu 22.04 + 24.04 / Fedora 40 + 41 / Arch) and 4 macOS variants (Sonoma / Sequoia / Tahoe arm64 / Tahoe Intel); release assets publish only if every cell is green
- [x] **`unrager doctor`** — one-shot setup health check (cookies, Ollama, gemma4) with actionable hints
- [x] **Filter auto-fallback** — classifier detects installed gemma4 variants at startup and substitutes if configured model is missing
- [x] **`filter⌀` status-bar indicator** — dim marker when the classifier is unavailable so users notice and can run `unrager doctor` to diagnose
- [x] **Expanded top-level `--help`** — TUI launch hint, Ollama/gemma4 dependency, per-OS config paths

## Next

Sorted by what would hurt a new user the most if unaddressed.

- [ ] **Hand-written release notes on tagged releases** — `--generate-notes` currently produces a bare compare-link. Adds 2 minutes per release; readers of the GitHub release page get an actual "what's in this" summary.
- [ ] **OAuth write-path client-ID clarity** — README makes forking-and-replacing sound optional. A published install pool sharing one X developer client ID risks per-client rate limits and X flagging cross-user traffic. Either: require users to set their own client ID before building (remove the embedded default), or make the current guidance in the README prominent and unambiguous. Only matters for `unrager tweet` / `unrager reply` — read and TUI are unaffected.
- [ ] **Uninstall story** — `install.sh --uninstall` that removes the binary and optionally offers to wipe `~/.config/unrager` + `~/.cache/unrager` (or the macOS equivalents). Right now users have to reverse the install by hand.
- [ ] **`unrager update`** — self-update subcommand that checks latest GitHub release, verifies SHA256, atomic-swap via `self_replace`. Would close the "how do I get the new version" loop without requiring users to re-run the installer.
- [ ] **Passive update nag in TUI** — once-a-day background check against GitHub releases, `↑ X.Y.Z` in the status bar when newer. Pairs with `unrager update`.
- [ ] **GHA Node 20 → 24 migration** — current workflows emit deprecation warnings on every run. Deadline June 2026. Set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` now to clean up the annotations.

## Maybe

- [ ] `/` in-buffer search within the current feed
- [ ] `--calm` flag on CLI commands (pipe filter into one-shot output)
- [ ] Filter rubric refinement based on real-world usage
- [ ] User avatars (small kitty-graphics thumbnails next to handles)
- [ ] `unrager doctor --json` for scripting / integration
- [ ] Multi-language filter rubric (key off `tweet.lang`)
- [ ] Fine-tuned small classifier (distilled from gemma4 verdicts)
- [ ] Mouse support
- [ ] Compose modal in TUI
- [ ] Homebrew tap (only if demand materializes; installer already serves the same audience)

## Blocked

- [ ] Likers list / notifications — query IDs live in X's lazy-loaded webpack chunks, not discoverable from `main.*.js`
- [ ] Full bookmarks list — same lazy-chunk issue; `:bookmarks` works with a search query only
