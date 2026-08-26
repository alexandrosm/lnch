__LNCH_DIR="$LNCH_INSTALL_DIR"
ps_win_path() {
    local p="$1" drv="" rest=""
    case "$p" in
        /mnt/[a-zA-Z]/*)
            drv="${p:5:1}"; rest="${p:6}" ;;
        /[a-zA-Z]/*)
            drv="${p:1:1}"; rest="${p:2}" ;;
        *)
            rest="$p" ;;
    esac
    drv="$(printf '%s' "$drv" | tr 'a-z' 'A-Z')"
    if [ -n "$drv" ]; then
        printf '%s:%s' "$drv" "${rest//\//\\}"
    else
        printf '%s' "${rest//\//\\}"
    fi
}
lnch() {
    local exe entry
    if command -v pwsh.exe >/dev/null 2>&1; then exe="pwsh.exe"
    elif command -v powershell.exe >/dev/null 2>&1; then exe="powershell.exe"
    else exe="powershell"; fi
    entry="$(ps_win_path "$__LNCH_DIR/entry.ps1")"
    MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 "$exe" -NoProfile -ExecutionPolicy Bypass -File "$entry" "$@"
}
