#!/usr/bin/env bash
set -euo pipefail

REPO="guitaripod/unrager"
INSTALL_DIR="${UNRAGER_INSTALL_DIR:-$HOME/.local/bin}"

err() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

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

RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")
TAG=$(printf '%s\n' "$RELEASE_JSON" \
    | grep '"tag_name"' \
    | head -n 1 \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
[ -n "$TAG" ] || err "could not determine latest release tag"
note "latest release: $TAG"

ASSET="unrager-${TAG}-${TARGET}.tar.gz"
URL_BASE="https://github.com/$REPO/releases/download/$TAG"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

note "downloading $ASSET"
curl -fsSL -o "$TMP/$ASSET" "$URL_BASE/$ASSET" \
    || err "failed to download $URL_BASE/$ASSET"

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

note "installed $("$INSTALL_DIR/unrager" --version)"

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

cat <<EOF

Next steps:
  unrager                  launch the TUI
  unrager --help           see all subcommands
  ollama pull gemma4       enable the local-LLM rage filter (optional)

EOF
