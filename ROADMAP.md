# Roadmap

Pre-launch and post-launch polish. Each item is a self-contained task an agent can pick up, work through, and ship independently.

**Convention:** one task per commit (or tight PR). Run the CI gate (`cargo fmt --all -- --check && cargo clippy --all-targets -- -D warnings && cargo test`) before pushing. Don't bundle unrelated items. When finishing a task, move it to the Completed section at the bottom with a one-line summary and the commit sha.

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

---

## P1 — Reputation and trust

### [ ] Site link check in a real paste context
**Goal:** OG card renders on Twitter, Discord, and Slack previews; install snippet copy works; demo plays.
**How:** paste the site URL into each platform's compose box, confirm the preview. Copy the install snippet from the site in a real browser, paste into a shell, confirm it's what you expect (no smart quotes, no zero-width chars). Open the carousel on mobile Safari and Firefox.
**Done when:** all three platform previews look right; install-copy yields a clean bash-executable string.

---

## P2 — Durability

### [ ] Telemetry-free usage signal
**Goal:** know whether the site install-script is being run, without shipping telemetry.
**How:** the install script is served from `unrager.com` — the access log on whatever host serves it is the signal. Document in an internal note (or as a comment in the site repo) where to check that, and what a healthy rate looks like after launch so drops are visible.
**Done when:** there's a one-liner (log grep, or dashboard link) that answers "did 10 or 10,000 people try to install it today."

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

- [x] **Ollama-missing graceful degradation pass** — `a17d03c` — translate now surfaces failures via a `TweetTranslateFailed` event; ask/brief errors route through a shared `ollama_error_hint` that adds `run unrager doctor` on connection failures.
- [x] **Audit `unrager doctor` output for the three broken-state personas** — `3ed6b47` — added a dedicated branch for an invalid `UNRAGER_COOKIES_PATH` override; all three personas now produce copy-pasteable fixes.
- [x] **Rework cookie/auth framing in README** — `3121125` — two-paragraph "How auth works" section above Quick start, reading vs writing split cleanly.
- [x] **Explicit Windows support statement in README** — `3121125` — WSL2 is the documented path; native Windows called out as not-implemented (no DPAPI backend).
- [x] **Changelog / GitHub release notes for 0.15.0** — `c18d35b` — `CHANGELOG.md` seeded with 0.13.0 → 0.15.0 plus `[Unreleased]`; CLAUDE.md release steps updated to roll it.
- [x] **Harden the bug-report issue template** — `bbbd055` — three mandatory code blocks with the exact shell commands (`--version`, `doctor`, log tail) pre-filled.
- [x] **`unrager --help` readthrough** — `d74819e` — filled in `-n`, `--json`, `--max-pages`, `--product` help text across 7 subcommands.
- [x] **Panic audit on common user paths** — `f0800b7` — audited every non-test `unwrap`/`expect`; documented the non-local invariant on `external.rs` viewer spawns with `.expect(...)`; no user-reachable panic remains.
- [x] **Query ID rotation early-warning** — `23cd9fd` — `examples/check_query_ids.rs` + `.github/workflows/query-ids-watch.yml` cron that opens or refreshes a tracking issue on drift.
