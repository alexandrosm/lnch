#!/usr/bin/env bash
# Installs/updates `lnch` in ~/.bashrc and ~/.zshrc.
# Removes both lnch and legacy project-starter lines (clean cutover).
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINE="[ -f \"$DIR/shell/lnch.sh\" ] && . \"$DIR/shell/lnch.sh\"  # lnch"

wire() {
    f="$1"
    touch "$f"
    sed -i '/# lnch/d; /# project-starter/d' "$f"
    printf '\n%s\n' "$LINE" >> "$f"
    echo "installed/updated: $f"
}

wire "$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && wire "$HOME/.zshrc"

echo ''
echo 'done. open a NEW terminal, then:  lnch'
