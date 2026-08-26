# Load the production Bash shim from disk; never pass shell bodies through argv.
_lnch_test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_lnch_test_dir/../shell/lnch.sh"
unset _lnch_test_dir
