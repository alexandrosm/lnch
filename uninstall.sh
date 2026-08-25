#!/usr/bin/env bash
# Removes project-starter lines from ~/.bashrc and ~/.zshrc.
for f in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$f" ] || continue
    if grep -qF '# project-starter' "$f"; then
        sed -i '/# project-starter/d' "$f"
        echo "removed lines from $f"
    else
        echo "nothing to remove: $f"
    fi
done
