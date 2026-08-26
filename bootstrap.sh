#!/usr/bin/env bash
# project-starter remote bootstrap for bash/zsh boxes:
#   curl -fsSL https://raw.githubusercontent.com/alexandrosm/project-starter/main/bootstrap.sh | bash
# Optional: ./bootstrap.sh v0.3.0 pins a tagged release (default: latest release,
# falling back to the main branch when the API is unreachable). Tagged downloads
# are SHA256-verified against the release's SHA256SUMS.
set -e

REPO="https://github.com/alexandrosm/project-starter"
API="https://api.github.com/repos/alexandrosm/project-starter"
DEST="$HOME/.project-starter"
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

mkdir -p "$DEST"

fetch_and_verify() {
    curl -fsSL "$REPO/releases/download/$VERSION/project-starter-$VERSION.zip" -o starter.zip
    curl -fsSL "$REPO/releases/download/$VERSION/SHA256SUMS" -o SHA256SUMS
    expected="$(grep "project-starter-$VERSION.zip" SHA256SUMS | awk '{print $1}')"
    actual="$(sha256sum starter.zip | awk '{print $1}')"
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
    unzip -q starter.zip && mv "project-starter-$VERSION"/* "$DEST"/ && rmdir "project-starter-$VERSION"
    rm -f starter.zip SHA256SUMS
fi

bash "$DEST/install.sh"

echo ''
echo 'done. open a NEW terminal, then:  start my-project'
