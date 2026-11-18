# Shared setup: a throwaway HOME and git config, a configuration written by hand, and repos in a temp directory.

setup() {
  T=$BATS_TEST_TMPDIR
  export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  unset ASSAY_CONFIG ASSAY_BASE GITHUB_EVENT_PATH assay_tools
  git config --global user.name Test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  git config --global protocol.file.allow always
  git config --global advice.detachedHead false
  # Detached auto-gc would race the teardown.
  git config --global gc.auto 0
  git config --global maintenance.auto false
  # shellcheck disable=SC2034 # used by the .bats files
  assay=$BATS_TEST_DIRNAME/../assay.sh
  no_checks
}

# no_checks: an empty configuration, pointed at by ASSAY_CONFIG.
no_checks() {
  export ASSAY_CONFIG=$T/config.json
  echo '{"version": 1, "checks": {}, "loosenings": []}' >"$ASSAY_CONFIG"
}

# check <name> <exec> [--fast] [--off] [--requires <glob>]: add a check to the configuration.
check() {
  local name=$1 exec=$2 fast=false enable=true requires=null
  shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --fast) fast=true ;;
      --off) enable=false ;;
      --requires)
        requires=$(jq -n --arg r "$2" '$r')
        shift
        ;;
    esac
    shift
  done
  jq --arg n "$name" --arg e "$exec" --argjson f "$fast" --argjson on "$enable" --argjson r "$requires" \
    '.checks[$n] = {exec: $e, fast: $f, enable: $on, requires: $r}' "$ASSAY_CONFIG" >"$ASSAY_CONFIG.new"
  mv "$ASSAY_CONFIG.new" "$ASSAY_CONFIG"
}

# loosening <check> <kind> <reason>: add a loosening to the configuration.
loosening() {
  jq --arg c "$1" --arg k "$2" --arg r "$3" '.loosenings += [{check: $c, kind: $k, reason: $r}]' \
    "$ASSAY_CONFIG" >"$ASSAY_CONFIG.new"
  mv "$ASSAY_CONFIG.new" "$ASSAY_CONFIG"
}

# commit_file <dir> <file> [content]: add and commit a file.
commit_file() {
  echo "${3:-$2}" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit --quiet -m "add $2"
}

# upstream: a "GitHub" repo with two commits on main ($T/up, a working copy, pushes to $T/origin.git), cloned into
# $T/work, the current directory.
upstream() {
  git init --quiet "$T/up"
  commit_file "$T/up" a.txt
  commit_file "$T/up" b.txt
  git clone --quiet --bare "$T/up" "$T/origin.git"
  git -C "$T/up" remote add origin "$T/origin.git"
  git -C "$T/up" fetch --quiet origin
  git clone --quiet "$T/origin.git" "$T/work"
  cd "$T/work" || return 1
}

# local_repo: a repo with one commit and no remote, the current directory.
local_repo() {
  git init --quiet "$T/work"
  commit_file "$T/work" a.txt
  cd "$T/work" || return 1
}

# sha <rev> [dir]
sha() { git -C "${2:-.}" rev-parse "$1"; }
short() { git -C "${2:-.}" rev-parse --short "$1"; }
