# project-starter for bash/zsh: thin shim into the PowerShell engine.
# Sourced by install.sh into your rc file. Flags: --yolo, --here.
# Dependency-free POSIX->Windows path conversion (/mnt/c, /c, and native
# Windows forms; tr-based, no cygpath).

if [ -n "${BASH_SOURCE:-}" ]; then
    __PROJECT_STARTER_SRC="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
    __PROJECT_STARTER_SRC="${(%):-%x}"
else
    __PROJECT_STARTER_SRC="$0"
fi
__PROJECT_STARTER_DIR="$(cd "$(dirname "$__PROJECT_STARTER_SRC")/.." && pwd)"

ps_win_path() {
    local p="$1"
    case "$p" in
        /mnt/[a-zA-Z]/*)
            printf '%s%s' \
                "$(printf '%s' "${p:5:1}" | tr 'a-z' 'A-Z'):" \
                "$(printf '%s' "${p:6}" | tr '/' '\\')"
            ;;
        /[a-zA-Z]/*)
            printf '%s%s' \
                "$(printf '%s' "${p:1:1}" | tr 'a-z' 'A-Z'):" \
                "$(printf '%s' "${p:2}" | tr '/' '\\')"
            ;;
        *)
            printf '%s' "$(printf '%s' "$p" | tr '/' '\\')"
            ;;
    esac
}

start() {
    local exe entry
    if command -v pwsh.exe >/dev/null 2>&1; then
        exe="pwsh.exe"
    elif command -v pwsh >/dev/null 2>&1; then
        exe="pwsh"
    elif command -v powershell.exe >/dev/null 2>&1; then
        exe="powershell.exe"
    else
        exe="powershell"
    fi
    entry="$(ps_win_path "$__PROJECT_STARTER_DIR/entry.ps1")"
    # MSYS2_ARG_CONV_EXCL/MSYS_NO_PATHCONV stop git-bash mangling args like foo/bar
    MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 "$exe" -NoProfile -ExecutionPolicy Bypass -File "$entry" "$@"
}
