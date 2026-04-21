# Roadmap

Pre-launch and post-launch polish. Each item is a self-contained task an agent can pick up, work through, and ship independently.

**Convention:** one task per commit (or tight PR). Run the CI gate (`cargo fmt --all -- --check && cargo clippy --all-targets -- -D warnings && cargo test`) before pushing. Don't bundle unrelated items. When finishing a task, strike it here in the same PR.

---

## P0 — First-contact experience

These determine whether a new user's first 60 seconds end in "wow" or "uninstall." Every one of them is a known unknown until exercised on a clean machine.

### [ ] Fresh-install smoke test on clean Linux
**Goal:** confirm `curl -fsSL https://unrager.com/install.sh | bash` → `unrager demo` works end-to-end on a never-touched Ubuntu LTS.
**How:** spin up a throwaway container (`docker run -it --rm ubuntu:24.04 bash`), install curl + bash, run the one-liner, then `unrager demo`. Record every point where something asked for a dependency, printed a scary warning, or silently hung. File each as a GitHub issue with `first-run` label.
**Done when:** either the flow works cleanly, or each rough edge has an issue.

### [ ] Fresh-install smoke test on clean macOS
**Goal:** same as above, on macOS (Apple Silicon). A fresh user on a work laptop is the realistic target.
**How:** a clean user account or a macOS VM. Same script, same note-taking.
**Done when:** README's "Works on macOS" claim is verified, or the gaps are filed.

### [ ] `cargo install unrager` from stable rustc, timed
**Goal:** confirm the crates.io path works on stable (no nightly required) and complete build time is <3 min on a modern laptop.
**How:** `rustup default stable && rustup update && cargo install unrager` in a clean `$CARGO_HOME`. Time it. If LTO SIGILLs on stable despite CLAUDE.md's note, add the workaround to `[profile.release]` or document the env var in README.
**Done when:** clean install succeeds on stable, timing recorded here, and any new requirement is in README.

### [x] Audit `unrager doctor` output for the three broken-state personas
**Goal:** `doctor` should be the single command that fixes every "unrager isn't working" DM.
**How:** run `unrager doctor` in three deliberately broken states — (a) no browser cookies found, (b) Ollama not installed or port unreachable, (c) stale query IDs (simulate by editing `~/.cache/unrager/query-ids.json`). For each: is the diagnosis correct? Is the fix one copy-pasteable command? If not, improve the relevant check in `src/cli/doctor.rs`.
**Done when:** all three states produce a diagnosis + fix that a non-Rust user can follow.
**Shipped:** all three personas produce clear diagnoses with copy-pasteable fixes; added a dedicated branch for an invalid `UNRAGER_COOKIES_PATH` override so the user knows to unset/retarget rather than chasing a "no cookie store found" false lead.

### [x] Ollama-missing graceful degradation pass
**Goal:** users without Ollama should get a working TUI with a clear, actionable hint — not silence.
**How:** stop Ollama (`systemctl --user stop ollama` or equivalent), run the TUI. Confirm the `filter off · doctor` hint shows. Press `A` (ask), `T` (translate), `B` (brief) — each should fail with a one-line user-visible message pointing at `doctor`, not hang or no-op. Grep `src/tui/app_llm.rs` for silent `return` branches.
**Done when:** every LLM-gated key produces visible feedback when Ollama is down.
**Shipped:** `translate_async` now surfaces failures via a new `TweetTranslateFailed` event (was silently hanging `translation_inflight`); ask/brief error statuses route through a shared `ollama_error_hint` that appends `run \`unrager doctor\`` on connection-style errors. The pre-flight "config missing" message was retitled from `(no ollama config)` to `· run \`unrager doctor\``.

---

## P1 — Reputation and trust

### [ ] Rework the cookie/auth framing in README
**Goal:** "we read your browser cookies" must land as "clever" not "malware."
**How:** add a short "How auth works" subsection near the top (before Quick start, or immediately after). Cover: what cookies are read (only `auth_token` and `ct0` from the X domain), what stays local (everything), that the code path is `src/auth/` and open-source, and the OAuth alternative for writes. One paragraph, not a wall.
**Done when:** README has a trust-inducing auth section above the fold.

### [ ] Explicit Windows support statement in README
**Goal:** no ambiguity.
**How:** one line in the install section. Either "Windows: use WSL2" or "Windows: unsupported, PRs welcome." Match current reality — the cookie-extraction path in `src/auth/` likely dictates which.
**Done when:** a Windows user reading README knows in 10 seconds whether to bother.

### [ ] Changelog / GitHub release notes for 0.15.0
**Goal:** people check "when was this last touched, and does the author care?" before installing.
**How:** either a `CHANGELOG.md` seeded with the last few versions from `git log`, or rich release notes on the existing GitHub release for 0.15.0 (and a habit of doing it going forward — maybe add a step to CLAUDE.md's release checklist).
**Done when:** the 0.15.0 GitHub release has a human-written summary, and there's a pattern for future releases.

### [ ] Site link check in a real paste context
**Goal:** OG card renders on Twitter, Discord, and Slack previews; install snippet copy works; demo plays.
**How:** paste the site URL into each platform's compose box, confirm the preview. Copy the install snippet from the site in a real browser, paste into a shell, confirm it's what you expect (no smart quotes, no zero-width chars). Open the carousel on mobile Safari and Firefox.
**Done when:** all three platform previews look right; install-copy yields a clean bash-executable string.

### [ ] Harden the bug-report issue template
**Goal:** every new issue arrives with `doctor` output and a log tail, so triage takes minutes not hours.
**How:** edit `.github/ISSUE_TEMPLATE/bug_report.md` to require (a) `unrager --version`, (b) `unrager doctor` output, (c) last 50 lines of `~/.cache/unrager/unrager.log.$(date +%Y-%m-%d)`, (d) reproduction steps. Use placeholders so users know what to paste where.
**Done when:** the template visibly pre-fills these sections on a new issue form.

---

## P2 — Durability

### [ ] Query ID rotation early-warning
**Goal:** when X rotates query IDs and the scraper fails, we know before users do.
**How:** add a daily or weekly GitHub Actions cron that runs a minimal auth-less scraper check. If fallback IDs stop matching the live ones, open an issue automatically. See `src/gql/` for the scraper module.
**Done when:** a workflow exists, has run successfully once, and has a documented failure mode (what happens when it opens an issue).

### [ ] Telemetry-free usage signal
**Goal:** know whether the site install-script is being run, without shipping telemetry.
**How:** the install script is served from `unrager.com` — the access log on whatever host serves it is the signal. Document in an internal note (or as a comment in the site repo) where to check that, and what a healthy rate looks like after launch so drops are visible.
**Done when:** there's a one-liner (log grep, or dashboard link) that answers "did 10 or 10,000 people try to install it today."

### [ ] `unrager --help` readthrough
**Goal:** `--help` should sell the CLI the way the README sells the TUI.
**How:** run `unrager --help` and each subcommand's `--help`. Check every description reads like a complete sentence, the examples are current, and nothing references removed flags. Clap attribute docs live across `src/main.rs` and `src/cli/*.rs`.
**Done when:** every help screen is proofread and each example actually works.

### [ ] Panic audit on common user paths
**Goal:** no `.unwrap()` on user-reachable paths.
**How:** `grep -rn 'unwrap()' src/` and for each hit in non-test code, ask "can a malformed X response, missing file, or failed fetch reach this?" Replace with `?` propagation + a `tracing::error!` where recoverable, or a graceful user-visible error. Don't touch `test_util.rs` or `#[cfg(test)]` blocks.
**Done when:** the remaining `.unwrap()` calls are either in tests or have a justifying comment.

---

## P3 — Growth

### [ ] Short asciinema/VHS clip of the Ollama filter catching rage in real time
**Goal:** social-post-shaped proof that it works. The existing hero GIF is good for README; a 10–15s clip of the `−N` counter ticking upward while scrolling through a politics-heavy feed is shareable.
**How:** VHS tape in `demos/`, record against `unrager demo` with Ollama running so the filter actually fires. Export as both GIF (for README/Twitter) and MP4 (for Mastodon/BlueSky).
**Done when:** `demos/filter-live.tape` exists, generates a clip, and the output is linked from README or site.

### [ ] Homebrew tap (optional, after traction)
**Goal:** `brew install unrager` is the macOS path of least resistance.
**How:** create a `homebrew-unrager` tap repo with a formula that pulls the prebuilt binary from GitHub Releases. Only worth doing once install-script volume justifies it — check the P2 usage signal first.
**Done when:** `brew install guitaripod/unrager/unrager` works on a clean mac.

---

## Completed

_(Move tasks here with a `- [x]` and a one-line summary when shipped.)_
