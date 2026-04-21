#!/usr/bin/env bash
set -euo pipefail

REPO="guitaripod/unrager"
INSTALL_DIR="${UNRAGER_INSTALL_DIR:-$HOME/.local/bin}"
FLAVOR="${UNRAGER_FLAVOR:-tui}"

err() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

case "$FLAVOR" in
    full|tui|cli) ;;
    *) err "UNRAGER_FLAVOR must be 'full', 'tui', or 'cli' (got: $FLAVOR)" ;;
esac

data_dirs() {
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "$HOME/Library/Application Support/unrager"
        echo "$HOME/Library/Caches/unrager"
    else
        echo "${XDG_CONFIG_HOME:-$HOME/.config}/unrager"
        echo "${XDG_CACHE_HOME:-$HOME/.cache}/unrager"
    fi
}

uninstall() {
    local binary="$INSTALL_DIR/unrager"
    if [ -f "$binary" ]; then
        rm "$binary"
        note "removed $binary"
    else
        note "no binary found at $binary"
    fi

    printf '\nRemove config and cache directories? [y/N] '
    read -r answer
    case "$answer" in
        [yY]*)
            while IFS= read -r dir; do
                if [ -d "$dir" ]; then
                    rm -rf "$dir"
                    note "removed $dir"
                fi
            done < <(data_dirs)
            ;;
        *)
            note "keeping data directories"
            ;;
    esac

    note "uninstall complete"
    exit 0
}

if [ "${1:-}" = "--uninstall" ]; then
    uninstall
fi

detect_target() {
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "$os-$arch" in
        Linux-x86_64)      echo "x86_64-unknown-linux-gnu" ;;
        Linux-aarch64)     echo "aarch64-unknown-linux-gnu" ;;
        Linux-arm64)       echo "aarch64-unknown-linux-gnu" ;;
        Darwin-x86_64)     echo "x86_64-apple-darwin" ;;
        Darwin-arm64)      echo "aarch64-apple-darwin" ;;
        *) err "unsupported platform: $os $arch" ;;
    esac
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "required command not found: $1"
}

sha256_verify() {
    local file="$1" expected="$2" actual
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        err "neither sha256sum nor shasum available; cannot verify checksum"
    fi
    [ "$actual" = "$expected" ] || err "checksum mismatch for $(basename "$file"): expected $expected, got $actual"
}

need_cmd curl
need_cmd tar
need_cmd uname

TARGET=$(detect_target)
note "detected target: $TARGET"
note "flavor: $FLAVOR"

RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")
TAG=$(printf '%s\n' "$RELEASE_JSON" \
    | grep '"tag_name"' \
    | head -n 1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
[ -n "$TAG" ] || err "could not determine latest release tag"
note "latest release: $TAG"

# asset naming: full flavor is unsuffixed for backward compat; tui/cli carry a flavor suffix
if [ "$FLAVOR" = "full" ]; then
    ASSET="unrager-${TAG}-${TARGET}.tar.gz"
else
    ASSET="unrager-${TAG}-${FLAVOR}-${TARGET}.tar.gz"
fi
URL_BASE="https://github.com/$REPO/releases/download/$TAG"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

note "downloading $ASSET"
if ! curl -fsSL -o "$TMP/$ASSET" "$URL_BASE/$ASSET"; then
    if [ "$FLAVOR" != "full" ]; then
        err "failed to download $URL_BASE/$ASSET — the '$FLAVOR' flavor may not exist for this release. try UNRAGER_FLAVOR=full or pick a newer release."
    fi
    err "failed to download $URL_BASE/$ASSET"
fi

note "downloading SHA256SUMS"
curl -fsSL -o "$TMP/SHA256SUMS" "$URL_BASE/SHA256SUMS" \
    || err "failed to download SHA256SUMS"

EXPECTED=$(grep " $ASSET$" "$TMP/SHA256SUMS" | awk '{print $1}')
[ -n "$EXPECTED" ] || err "SHA256SUMS has no entry for $ASSET"

note "verifying checksum"
sha256_verify "$TMP/$ASSET" "$EXPECTED"

note "extracting to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$TMP/$ASSET" -C "$TMP"
install -m 755 "$TMP/unrager" "$INSTALL_DIR/unrager"

if [ "$(uname -s)" = "Darwin" ]; then
    xattr -d com.apple.quarantine "$INSTALL_DIR/unrager" 2>/dev/null || true
fi

note "installed $("$INSTALL_DIR/unrager" --version) · flavor: $FLAVOR"

case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        note "$INSTALL_DIR is on your PATH"
        ;;
    *)
        cat <<EOF

$INSTALL_DIR is not on your PATH. Add one of these lines to your shell rc:

  bash    echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.bashrc
  zsh     echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.zshrc
  fish    fish_add_path \$HOME/.local/bin

Then restart your shell or source the rc file.
EOF
        ;;
esac

case "$FLAVOR" in
    full)
        cat <<EOF

Next steps:
  unrager                  launch the TUI
  unrager serve            start the HTTP server + web client on :7777
  unrager doctor           check cookies, Ollama, and filter setup
  ollama pull gemma4       enable the local-LLM rage filter (optional)
  unrager --help           all subcommands

Want a leaner install? re-run with:
  UNRAGER_FLAVOR=tui  curl -fsSL unrager.com/install.sh | bash   # default (~5 MB smaller)
  UNRAGER_FLAVOR=cli  curl -fsSL unrager.com/install.sh | bash   # CLI only (~11 MB smaller)

EOF
        ;;
    tui)
        cat <<EOF

Next steps:
  unrager                  launch the TUI
  unrager doctor           check cookies, Ollama, and filter setup
  ollama pull gemma4       enable the local-LLM rage filter (optional)
  unrager --help           all subcommands

Want the web/mobile server too? re-run with:
  UNRAGER_FLAVOR=full curl -fsSL unrager.com/install.sh | bash

EOF
        ;;
    cli)
        cat <<EOF

Next steps:
  unrager doctor           check cookies and setup
  unrager --help           all subcommands
  unrager home --json      pipe a timeline to jq
  unrager auth login       set up OAuth for the write path

Want the TUI too? re-run with:
  UNRAGER_FLAVOR=tui  curl -fsSL unrager.com/install.sh | bash
  UNRAGER_FLAVOR=full curl -fsSL unrager.com/install.sh | bash   # includes web/mobile server

EOF
        ;;
esac

cat <<EOF
Uninstall:
  curl -fsSL https://unrager.com/install.sh | bash -s -- --uninstall

EOF
