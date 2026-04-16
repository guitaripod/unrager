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

- [x] **Automated release notes** — conventional-commit parser in the release workflow groups commits by category (Features, Fixes, Tuning, Styling), strips chore/docs noise, appends a compare link.
- [x] **OAuth write-path client-ID clarity** — README write-path setup now makes replacing the embedded Client ID an explicit numbered step with a rationale callout.
- [x] **Uninstall story** — `install.sh --uninstall` removes the binary, optionally wipes config/cache. Respects `UNRAGER_INSTALL_DIR`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, and macOS `~/Library` paths.
- [x] **`unrager update`** — self-update subcommand: checks latest GitHub release, downloads the platform binary, verifies SHA256, atomic-swaps via `self-replace`.
- [x] **Passive update nag in TUI** — once-a-day background check against GitHub releases. `↑X.Y.Z` appears in the status bar when a newer version exists.
- [x] **GHA Node 20 → 24 migration** — bumped all official actions from `@v4` to `@v5` (native Node 24). No more deprecation warnings.

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
