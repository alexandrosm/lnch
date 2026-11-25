#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARCHIVE="$WORK/lnch-vtest.zip"
git -C "$ROOT" archive --format=zip --output="$ARCHIVE" HEAD
read -r HASH _ < <(sha256sum -b "$ARCHIVE")
printf '%s  lnch-vtest.zip\n' "$HASH" > "$WORK/SHA256SUMS"

export HOME="$WORK/home with spaces"
export PATH="$WORK/bin:$PATH" FIXTURE_ZIP="$ARCHIVE" FIXTURE_SUMS="$WORK/SHA256SUMS"
export FIXTURE_TAR="$WORK/main.tar.gz" GIT_ALLOW_PROTOCOL=file
mkdir -p "$WORK/bin" "$HOME" "$WORK/run"
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
    */main.tar.gz) cat "$FIXTURE_TAR" ;;
    */releases/latest) exit 1 ;;  # offline: exercise the main fallback
    *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/curl"

cd "$WORK/run"
bootstrap() { bash "$ROOT/bootstrap.sh" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
dest="$HOME/.lnch"
bootstrap vtest

test -f "$dest/Lnch.ps1"
test -f "$dest/WindowsTerminal.ps1"
test -f "$dest/AgentTerm.ps1"
test -f "$dest/Dashboard.ps1"
test -f "$dest/shell/lnch.sh"
test ! -e "$WORK/run/.github"
bash -c 'source "$HOME/.bashrc"; declare -F lnch >/dev/null'

project="$dest/projects/keep me/work.txt"
legacy="$HOME/.project-starter/projects/older/work.txt"
mkdir -p "$(dirname "$project")" "$(dirname "$legacy")"
printf 'ongoing work\n' > "$project"
printf 'unmigrated work\n' > "$legacy"
printf '{"custom":{"caps":{}}}\n' > "$dest/agents.json"
check_user_data() {
    [[ -f "$project" && $(<"$project") == 'ongoing work' ]] || fail 'update lost a project'
    [[ -f "$dest/agents.json" && $(<"$dest/agents.json") == '{"custom":{"caps":{}}}' ]] || fail 'update lost the custom agent registry'
    [[ -f "$legacy" && $(<"$legacy") == 'unmigrated work' ]] || fail 'update lost legacy project data'
}

printf '%s *lnch-vtest.zip\r\n' "$HASH" > "$FIXTURE_SUMS"
bootstrap vtest
check_user_data

# Mark a shipped file so a partial overlay cannot masquerade as a rejection.
printf '\n# previous installed engine\n' >> "$dest/Lnch.ps1"
cp "$dest/Lnch.ps1" "$WORK/previous.ps1"
cp "$HOME/.bashrc" "$WORK/previous.bashrc"
expect_rejection() {
    if bootstrap vtest; then fail "accepted $1"; fi
    cmp "$WORK/previous.ps1" "$dest/Lnch.ps1" || fail "$1 changed the installed engine"
    cmp "$WORK/previous.bashrc" "$HOME/.bashrc" || fail "$1 changed the profile"
    check_user_data
}
printf '%s  lnch-vtest.zip.old\n' "$HASH" > "$FIXTURE_SUMS"
expect_rejection 'a checksum for a different filename'
printf '%064d  lnch-vtest.zip\n' 0 > "$FIXTURE_SUMS"
expect_rejection 'a bad checksum'
FIXTURE_ZIP="$WORK/incomplete.zip"
git -C "$ROOT" archive --format=zip --output="$FIXTURE_ZIP" HEAD Lnch.ps1 entry.ps1 install.sh
read -r incomplete_hash _ < <(sha256sum -b "$FIXTURE_ZIP")
printf '%s  lnch-vtest.zip\n' "$incomplete_hash" > "$FIXTURE_SUMS"
expect_rejection 'a verified archive missing the Bash shim'

# An existing archive install stays an archive on the main-branch fallback.
git -C "$ROOT" archive --format=tar.gz --prefix=lnch-main/ --output="$FIXTURE_TAR" HEAD
bootstrap
check_user_data
[[ ! -e "$dest/.git" ]] || fail 'main fallback converted an existing archive install into a checkout'
tar -xOzf "$FIXTURE_TAR" lnch-main/Lnch.ps1 | cmp - "$dest/Lnch.ps1" || fail 'main fallback did not update the engine'

# First-time main installs with Git still produce a usable checkout.
(
    export HOME="$WORK/clone home"
    mkdir -p "$HOME"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    upstream=$(git -C "$ROOT" rev-parse --show-toplevel)
    git config --global "url.$upstream.insteadOf" https://github.com/alexandrosm/lnch.git
    bootstrap main
    [[ -d "$HOME/.lnch/.git" && $(git -C "$HOME/.lnch" rev-parse HEAD) == "$(git -C "$ROOT" rev-parse HEAD)" ]] || fail 'fresh main install is not a usable checkout'
)

cat > "$WORK/bin/wslpath" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '\\wsl.localhost\Ubuntu\home\hero\.lnch\entry.ps1'
STUB
chmod +x "$WORK/bin/wslpath"
PATH="$WORK/bin:$PATH" LNCH_SH="$ROOT/shell/lnch.sh" bash -c \
    '. "$LNCH_SH"; test "$(ps_win_path /home/hero/.lnch/entry.ps1)" = "\\\\wsl.localhost\\Ubuntu\\home\\hero\\.lnch\\entry.ps1"'

echo 'RESULT: BASH BOOTSTRAP PASS'
