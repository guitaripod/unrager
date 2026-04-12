# unrager demos

Scriptable screen captures built with [VHS](https://github.com/charmbracelet/vhs). Each `.tape` file is a declarative script; running `vhs <file>.tape` produces a GIF, an MP4, and one or more PNG screenshots in `demos/out/`.

## Dependencies

- `vhs` — `go install github.com/charmbracelet/vhs@latest` (or `pacman -S vhs`)
- `ttyd` — prebuilt: `curl -sL -o ~/bin/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 && chmod +x ~/bin/ttyd` (or `pacman -S ttyd`)
- `ffmpeg` — `pacman -S ffmpeg`
- A release build: `cargo build --release`
- Ollama running with `gemma4:latest` pulled (the filter demos hit it live)
- A logged-in Vivaldi session with x.com cookies

All tapes set `UNRAGER_DISABLE_KITTY=1` because VHS renders through xterm.js, which doesn't speak the kitty graphics protocol — without the override the inline image placeholders leak fg colors all over the media rows.

## Tapes

| tape | output | what it shows |
|---|---|---|
| `home.tape` | `out/home.{gif,mp4}`, `home-initial.png`, `home-scrolled.png` | launch, initial home feed with filter running, scroll with `j` |
| `filter.tape` | `out/filter.{gif,mp4}`, `filter-on.png`, `filter-off.png` | `c` toggle — hidden tweets are physically absent when on |
| `detail.tape` | `out/detail.{gif,mp4}`, `detail-open.png`, `detail-reply.png` | `l`/`Enter` to push a tweet into detail, unified list with focal + replies, `j/k` nav |
| `expand.tape` | `out/expand.{gif,mp4}`, `expand.png` | `x` expands the selected tweet body in place |
| `help.tape` | `out/help.{gif,mp4}`, `help.png` | `?` overlays full key bindings |
| `command.tape` | `out/command.{gif,mp4}`, `command-user.png`, `command-search.png` | `:user jack`, `:search rust lang`, `:home` |
| `overview.tape` | `out/overview.{gif,mp4}` | the grand tour — launch, scroll, filter toggle, detail pane, help, quit |

## Running

```bash
# single tape
vhs demos/home.tape

# all tapes
for tape in demos/*.tape; do vhs "$tape"; done
```

Each tape takes ~15-45s depending on how much the script sleeps. The scripts deliberately leave generous `Sleep` time after launch so gemma4 can classify the first page before screenshots are taken.

## Notes on what won't capture

Inline media (photos/videos) **will not render** in VHS captures. VHS uses xterm.js which doesn't implement the kitty graphics protocol. The tapes force `UNRAGER_DISABLE_KITTY=1` so the app falls back to the colored `▣`/`▶`/`↻` header icon instead of emitting placeholder cells that would otherwise leak as colored blocks.

For a demo that actually shows the inline kitty images, screen-record a real Ghostty window with `kooha`, `wf-recorder`, or `OBS Studio`.

## Tweaking

All tapes share the same visual settings (Catppuccin Mocha theme, 1600×960, 14pt, 60ms typing). Edit at the top of each tape to change. For deterministic demos you'd also need a fixture layer the app doesn't currently have — outputs will vary run-to-run as real X content changes.
