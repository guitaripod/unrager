---
name: Bug report
about: Something's broken in unrager
title: ''
labels: bug
assignees: ''
---

<!--
Thanks for filing a bug. The three sections below (version, doctor, log tail) let us triage
in minutes instead of hours — please run the commands as-is and paste their output, even if
they look unrelated. Redact anything sensitive (handles, tokens, cookie values) before posting.
-->

## What happened

<!-- One or two sentences. What did you do, what did you expect, what did you see? -->

## Reproduction

<!-- Exact commands / key sequences. Copy-paste friendly. Start from "I ran `unrager ...`". -->

1.
2.
3.

## `unrager --version`

```
$ unrager --version
<paste output here>
```

## `unrager doctor`

<!-- Required. Covers cookies, Ollama, gemma4, query IDs in one shot. Nine times out of ten
     the fix is in this output. -->

```
$ unrager doctor
<paste output here>
```

## Log tail

<!-- Required for any bug that happens inside the TUI or during a fetch. Paste the last 50
     lines of today's log. On macOS the log path is `~/Library/Caches/unrager/...`. -->

```
$ tail -n 50 ~/.cache/unrager/unrager.log.$(date +%Y-%m-%d)
<paste output here>
```

## Environment

- OS + distro: <!-- e.g. Arch Linux, macOS 15.3 (Apple Silicon), Ubuntu 24.04 under WSL2 -->
- Terminal: <!-- e.g. Ghostty 1.1.3, Kitty 0.36, WezTerm 20240203 -->
- Browser whose cookies are being used: <!-- Vivaldi / Chrome / Brave / Edge / Arc / Opera -->
- Installed via: <!-- curl | bash (oneliner) / cargo install / cargo install --path . -->
