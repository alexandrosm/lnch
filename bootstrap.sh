#!/usr/bin/env bash
# project-starter remote bootstrap for bash/zsh boxes:
#   curl -fsSL https://raw.githubusercontent.com/alexandrosm/project-starter/main/bootstrap.sh | bash
# Downloads the repo to ~/.project-starter and wires up the bash/zsh face.
set -e

REPO="https://github.com/alexandrosm/project-starter"
DEST="$HOME/.project-starter"

if [ -d "$DEST/.git" ]; then
    echo 'updating existing clone...'
    git -C "$DEST" pull --ff-only
else
    rm -rf "$DEST"
    mkdir -p "$DEST"
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 "$REPO.git" "$DEST"
    else
        echo 'git not found - falling back to tarball...'
        curl -fsSL "$REPO/archive/refs/heads/main.tar.gz" | tar -xz -C "$DEST" --strip-components=1
    fi
fi

bash "$DEST/install.sh"

echo ''
echo 'done. open a NEW terminal, then:  start my-project'
