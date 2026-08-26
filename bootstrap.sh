#!/usr/bin/env bash
# lnch remote bootstrap for bash/zsh boxes:
#   curl -fsSL https://raw.githubusercontent.com/alexandrosm/lnch/main/bootstrap.sh | bash
# Optional: ./bootstrap.sh vX.Y.Z pins a tagged release (default: latest release,
# falling back to the main branch when the API is unreachable). Tagged downloads
# are SHA256-verified against the release's SHA256SUMS.
set -e

REPO="https://github.com/alexandrosm/lnch"
API="https://api.github.com/repos/alexandrosm/lnch"
DEST="$HOME/.lnch"
LEGACY_DEST="$HOME/.project-starter"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo 'resolving latest release...'
    if VERSION="$(curl -fsSL "$API/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"; [ -n "$VERSION" ]; then
        echo "latest release: $VERSION"
    else
        echo 'could not reach the GitHub API; falling back to the main branch'
        VERSION='main'
    fi
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$DEST"

fetch_and_verify() {
    curl -fsSL "$REPO/releases/download/$VERSION/lnch-$VERSION.zip" -o "$WORK_DIR/lnch.zip"
    curl -fsSL "$REPO/releases/download/$VERSION/SHA256SUMS" -o "$WORK_DIR/SHA256SUMS"
    IFS=' ' read -r expected _ < <(grep "lnch-$VERSION.zip" "$WORK_DIR/SHA256SUMS")
    IFS=' ' read -r actual _ < <(sha256sum "$WORK_DIR/lnch.zip")
    [ -n "$expected" ] || { echo 'SHA256SUMS missing archive entry'; exit 1; }
    [ "$actual" = "$expected" ] || { echo "checksum mismatch: expected $expected got $actual"; exit 1; }
    echo 'checksum verified'
}

if [ -d "$DEST/.git" ]; then
    echo 'updating existing clone...'
    git -C "$DEST" pull --ff-only
elif [ "$VERSION" = 'main' ]; then
    rm -rf "$DEST"
    mkdir -p "$DEST"
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 "$REPO.git" "$DEST"
    else
        curl -fsSL "$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$DEST" --strip-components=1
    fi
else
    fetch_and_verify
    rm -rf "$DEST"
    mkdir -p "$DEST"
    unzip -q "$WORK_DIR/lnch.zip" -d "$DEST"
fi

bash "$DEST/install.sh"
rm -rf "$LEGACY_DEST"

echo ''
echo 'done. open a NEW terminal, then:  lnch my-project'
