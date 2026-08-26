# lnch for bash/zsh: thin shim into the PowerShell engine.
# Sourced by install.sh into your rc file. Flags: --yolo, --here.
# Converts MSYS and WSL paths only when dispatching to Windows PowerShell.
# WSL uses wslpath for Linux-home UNC paths; Git Bash needs no cygpath.

if [ -n "${BASH_SOURCE:-}" ]; then
    __LNCH_SRC="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
    __LNCH_SRC="${(%):-%x}"
else
    __LNCH_SRC="$0"
fi
__LNCH_DIR="$(cd "$(dirname "$__LNCH_SRC")/.." && pwd)"

ps_win_path() {
    local p="$1"
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$p"
        return
    fi
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

lnch() {
    local exe entry
    if command -v pwsh >/dev/null 2>&1; then
        exe="$(command -v pwsh)"
    elif command -v pwsh.exe >/dev/null 2>&1; then
        exe="$(command -v pwsh.exe)"
    elif command -v powershell >/dev/null 2>&1; then
        exe="$(command -v powershell)"
    elif command -v powershell.exe >/dev/null 2>&1; then
        exe="$(command -v powershell.exe)"
    else
        printf '%s\n' 'lnch: PowerShell is required (pwsh or powershell.exe)' >&2
        return 127
    fi
    case "$exe" in
        *.exe|/[a-zA-Z]/*) entry="$(ps_win_path "$__LNCH_DIR/entry.ps1")" ;;
        *) entry="$__LNCH_DIR/entry.ps1" ;;
    esac
    # Stop MSYS2 from converting prompt arguments such as foo/bar.
    MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 "$exe" -NoProfile -ExecutionPolicy Bypass -File "$entry" "$@"
}
