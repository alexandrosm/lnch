#!/usr/bin/env bash
# Installs the `start` shim into ~/.bashrc (and ~/.zshrc when present).
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINE="[ -f \"$DIR/shell/start.sh\" ] && . \"$DIR/shell/start.sh\"  # project-starter"

add_to() {
    f="$1"
    touch "$f"
    if grep -qF '# project-starter' "$f"; then
        echo "already installed: $f"
    else
        printf '\n%s\n' "$LINE" >> "$f"
        echo "installed:         $f"
    fi
}

add_to "$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && add_to "$HOME/.zshrc"

echo ''
echo 'ready. open a NEW bash/zsh window, then:'
echo '  start my-app build a snake game   # --yolo / --here supported'
echo 'note: -here returns you to the ORIGINAL directory after the agent exits'
echo '      (the engine runs in a child PowerShell process).'
