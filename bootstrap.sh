#!/usr/bin/env bash
# lnch remote bootstrap for bash/zsh boxes:
#   curl -fsSL https://raw.githubusercontent.com/alexandrosm/lnch/main/bootstrap.sh | bash
# Optional: ./bootstrap.sh vX.Y.Z pins a tagged release (default: latest release,
# falling back to the main branch when the API is unreachable). Tagged downloads
# are SHA256-verified against the release's SHA256SUMS.
set -euo pipefail

REPO="https://github.com/alexandrosm/lnch"
API="https://api.github.com/repos/alexandrosm/lnch"
DEST="${HOME:?HOME must be set}/.lnch"
LEGACY_DEST="$HOME/.project-starter"
VERSION="${1:-}"

fetch_and_verify() {
    local asset="lnch-$VERSION.zip" expected='' digest filename actual
    curl -fsSL "$REPO/releases/download/$VERSION/$asset" -o "$WORK_DIR/lnch.zip"
    curl -fsSL "$REPO/releases/download/$VERSION/SHA256SUMS" -o "$WORK_DIR/SHA256SUMS"
    while read -r digest filename || [[ -n "$digest" ]]; do
        filename=${filename%$'\r'}
        if [[ ${filename#\*} == "$asset" && $digest =~ ^[[:xdigit:]]{64}$ ]]; then
            expected=$(printf '%s' "$digest" | tr 'A-F' 'a-f')
            break
        fi
    done < "$WORK_DIR/SHA256SUMS"
    [[ -n "$expected" ]] || { echo "SHA256SUMS missing entry for $asset" >&2; exit 1; }
    read -r actual _ < <(sha256sum -b "$WORK_DIR/lnch.zip")
    [[ $actual == "$expected" ]] || { echo "checksum mismatch for $asset" >&2; exit 1; }
    echo 'checksum verified'
}

if [[ -e "$DEST/.git" ]]; then
    echo 'updating existing clone...'
    git -C "$DEST" pull --ff-only
else
    if [[ -z "$VERSION" ]]; then
        echo 'resolving latest release...'
        if VERSION=$(curl -fsSL "$API/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') && [[ -n "$VERSION" ]]; then
            echo "latest release: $VERSION"
        else
            echo 'could not resolve the latest release; falling back to the main branch'
            VERSION=main
        fi
    fi

    WORK_DIR=$(mktemp -d)
    trap 'rm -rf -- "$WORK_DIR"' EXIT
    payload="$WORK_DIR/payload"
    mkdir "$payload"
    if [[ $VERSION == main ]]; then
        if [[ ! -e "$DEST" ]] && command -v git >/dev/null 2>&1; then
            git clone --depth 1 "$REPO.git" "$payload"
        else
            curl -fsSL "$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$payload" --strip-components=1
        fi
    else
        fetch_and_verify
        unzip -q "$WORK_DIR/lnch.zip" -d "$payload"
    fi

    for required in Lnch.ps1 entry.ps1 install.sh shell/lnch.sh; do
        [[ -f "$payload/$required" ]] || { echo "payload missing $required; installation unchanged" >&2; exit 1; }
    done
    # Projects and the optional agents.json can live alongside shipped files.
    mkdir -p "$DEST"
    cp -R "$payload/." "$DEST/"
fi

bash "$DEST/install.sh"
if [[ -d "$LEGACY_DEST" ]]; then
    echo "left $LEGACY_DEST in place; check it for projects before removing it"
fi

echo ''
echo 'done. open a NEW terminal, then:  lnch my-project'
