#!/usr/bin/env bash
# Removes lnch and legacy project-starter rc lines.
for f in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$f" ] || continue
    if grep -qE '# (lnch|project-starter)' "$f"; then
        sed -i '/# lnch/d; /# project-starter/d' "$f"
        echo "removed lines from $f"
    else
        echo "nothing to remove: $f"
    fi
done
