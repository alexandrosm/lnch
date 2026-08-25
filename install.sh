#!/usr/bin/env bash
# Installs/updates the `start` shim into ~/.bashrc (and ~/.zshrc when present).
# Replaces any previous project-starter lines (idempotent + path-migration safe).
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINE="[ -f \"$DIR/shell/start.sh\" ] && . \"$DIR/shell/start.sh\"  # project-starter"

wire() {
    f="$1"
    touch "$f"
    sed -i '/# project-starter/d' "$f"
    printf '\n%s\n' "$LINE" >> "$f"
    echo "installed/updated: $f"
}

wire "$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && wire "$HOME/.zshrc"

echo ''
echo 'done. open a NEW terminal, then:  start my-project'
echo 'note: -here returns you to the ORIGINAL directory after the agent exits'
echo '      (the engine runs in a child PowerShell process).'
