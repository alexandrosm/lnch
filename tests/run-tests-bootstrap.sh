#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARCHIVE="$WORK/lnch-vtest.zip"
(
    cd "$ROOT"
    git archive --format=zip --output="$ARCHIVE" HEAD
)
IFS=' ' read -r HASH _ < <(sha256sum "$ARCHIVE")
printf '%s  lnch-vtest.zip\n' "$HASH" > "$WORK/SHA256SUMS"

mkdir -p "$WORK/bin" "$WORK/home" "$WORK/run"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -eu
url=''
out=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            out="$2"
            shift 2
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done
case "$url" in
    */SHA256SUMS) cp "$FIXTURE_SUMS" "$out" ;;
    *.zip) cp "$FIXTURE_ZIP" "$out" ;;
    *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/curl"

(
    cd "$WORK/run"
    PATH="$WORK/bin:$PATH" \
    HOME="$WORK/home" \
    FIXTURE_ZIP="$ARCHIVE" \
    FIXTURE_SUMS="$WORK/SHA256SUMS" \
        bash "$ROOT/bootstrap.sh" vtest
)

test -f "$WORK/home/.lnch/Lnch.ps1"
test -f "$WORK/home/.lnch/shell/lnch.sh"
test ! -e "$WORK/run/.github"
HOME="$WORK/home" bash -c 'source "$HOME/.bashrc"; declare -F lnch >/dev/null'

echo 'RESULT: BASH BOOTSTRAP PASS'
