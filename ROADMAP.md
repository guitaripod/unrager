# Roadmap

## Done

- [x] Cookie-auth reads (home, user, search, mentions, bookmarks, thread, read)
- [x] OAuth 2.0 PKCE write path (tweet, reply, media upload)
- [x] Interactive TUI (split detail, command palette, history, session persistence)
- [x] Local-LLM rage filter (gemma4 via Ollama, SQLite cache, editable rubric)
- [x] Inline media via kitty graphics (Ghostty, Kitty, WezTerm)
- [x] Color-hashed @handles, zebra rows, theme-aware rendering

## Next

- [ ] `/` in-buffer search within the current feed
- [ ] `--calm` flag on CLI commands (pipe filter into one-shot output)
- [ ] Filter rubric refinement based on real-world usage
- [ ] User avatars (small kitty-graphics thumbnails next to handles)

## Blocked

- [ ] Likers list / notifications — query IDs live in X's lazy-loaded webpack chunks, not discoverable from `main.*.js`
- [ ] Full bookmarks list — same lazy-chunk issue; `:bookmarks` works with a search query only

## Maybe

- [ ] Multi-language filter rubric (key off `tweet.lang`)
- [ ] Fine-tuned small classifier (distilled from gemma4 verdicts)
- [ ] Mouse support
- [ ] Compose modal in TUI
