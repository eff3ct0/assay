#!/usr/bin/env bash
# assay: a repo's named checks, declared in its devenv through assay's devenv module (devenv/) and run the same way
# from pre-commit, `devenv test` and an agent's `devenv shell`. The module hands the checks over as one JSON file
# whose path is ASSAY_CONFIG.
set -euo pipefail

# The package sets assay_tools (git, jq, coreutils) on the line before this script. assay's own commands find them
# first; each check runs with the PATH assay was called with, so it sees the devenv's tools, not assay's.
caller_path=$PATH
if [ -n "${assay_tools:-}" ]; then PATH=$assay_tools:$PATH; fi

# The whole fast set's budget, in seconds, with a warm cache. Going over it fails nothing.
fast_budget=5
# Check names become log file names.
name_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'

usage_text() {
  cat <<'EOF'
usage: assay check [--fast] [--base <rev>] [<check>...]    run the repo's checks
       assay check --list                                  list them, fast ones marked

Run it inside the repo's devenv (devenv shell -- assay check), which sets ASSAY_CONFIG.
The base of the change: --base, else ASSAY_BASE, else GitHub's event (GITHUB_EVENT_PATH), else the
fork point of HEAD from the default branch, else their merge base. assay never fetches.
Exit codes: 0 every selected check passed, 1 at least one failed, 2 assay could not run.
EOF
}

# Every exit goes through these, so that any other exit (an unexpected failure under `set -e`) becomes exit 2 and
# never passes for a run's 0 or 1.
exiting=
finish() {
  exiting=1
  exit "$1"
}
die() {
  echo "assay: $*" >&2
  finish 2
}
usage() {
  usage_text >&2
  finish 2
}
usage_error() {
  echo "assay: $*" >&2
  usage
}
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
  local rc=$?
  if [ -z "$exiting" ] && [ "$rc" -ne 0 ]; then
    echo "assay: unexpected failure (exit $rc)" >&2
    exit 2
  fi
}
trap on_exit EXIT
trap 'echo >&2; finish 130' INT TERM

# assay's own git calls never fetch, not even the missing objects of a partial clone. Checks don't see this function.
git() { GIT_NO_LAZY_FETCH=1 command git "$@"; }

# The configuration, validated whole before anything is printed, and emitted as shell assignments (strings quoted
# with @sh) that end with config_loaded=1.
# shellcheck disable=SC2016 # jq's $variables, not the shell's
config_jq='
def fail($m): "\($m)\n" | halt_error(1);
def text: type == "string" and length > 0;
def check_ok($n):
  if type != "object" then fail("check \($n): not an object")
  elif (.exec | text | not) then fail("check \($n): exec must be a non-empty string")
  elif (.fast | type) != "boolean" then fail("check \($n): fast must be true or false")
  elif (.enable | type) != "boolean" then fail("check \($n): enable must be true or false")
  elif .requires != null and (.requires | text | not) then fail("check \($n): requires must be null or a non-empty string")
  else . end;
def loosening_ok($checks):
  if type != "object" then fail("a loosening is not an object")
  elif (.check | type) != "string" or (.check as $k | $checks | has($k) | not) then fail("loosening of an unknown check \(.check | tojson)")
  elif (.kind | IN("off", "exec") | not) then fail("loosening of \(.check): unknown kind \(.kind | tojson)")
  elif (.reason | text | not) then fail("loosening of \(.check) has no reason")
  else . end;
def validate:
  if type != "object" then fail("not a JSON object")
  elif .version != 1 then fail("unknown version \(.version | tojson)")
  elif (.checks | type) != "object" then fail("checks must be an object")
  elif (.loosenings | type) != "array" then fail("loosenings must be an array")
  else
    . as $c
    | reduce ($c.checks | keys[]) as $n (null;
        if ($n | test($name_re) | not) then fail("bad check name \($n | tojson)")
        else ($c.checks[$n] | check_ok($n)) | null end)
    | reduce $c.loosenings[] as $l (null; ($l | loosening_ok($c.checks)) | null)
    | $c
  end;
[inputs]
| if length != 1 then fail("expected one JSON document, found \(length)") else .[0] end
| validate
| (.checks | keys[] as $n | .[$n] as $c
    | "names+=(\($n | @sh))",
      "c_exec[\($n | @sh)]=\($c.exec | @sh)",
      "c_fast[\($n | @sh)]=\(if $c.fast then 1 else 0 end)",
      "c_enable[\($n | @sh)]=\(if $c.enable then 1 else 0 end)",
      "c_requires[\($n | @sh)]=\($c.requires // "" | @sh)"),
  (.loosenings[] | "loose_check+=(\(.check | @sh)) loose_kind+=(\(.kind | @sh)) loose_reason+=(\(.reason | @sh))"),
  "config_loaded=1"
'

names=()
declare -A c_exec=() c_fast=() c_enable=() c_requires=()
loose_check=()
loose_kind=()
loose_reason=()
config_loaded=0

load_config() {
  local cfg=${ASSAY_CONFIG:-} out
  [ -n "$cfg" ] || die "ASSAY_CONFIG is not set: run assay inside the repo's devenv (devenv shell -- assay check)"
  if [ ! -f "$cfg" ] || [ ! -r "$cfg" ]; then die "cannot read the configuration $cfg (ASSAY_CONFIG)"; fi
  if ! out=$(jq -n -r --arg name_re "$name_re" "$config_jq" "$cfg" 2>&1); then
    die "invalid configuration $cfg: $out"
  fi
  eval "$out"
  [ "$config_loaded" = 1 ] || die "invalid configuration $cfg: incomplete"
}

list_checks() {
  local n
  for n in "${names[@]}"; do
    if [ "${c_enable[$n]}" != 1 ]; then continue; fi
    if [ "${c_fast[$n]}" = 1 ]; then echo "$n (fast)"; else echo "$n"; fi
  done
}

opt_fast=0
opt_list=0
opt_base=
opt_base_set=0
wanted=()
selected=()

# The checks to run, in name order: the named ones, or every enabled one; with --fast, only fast ones.
select_checks() {
  local n w
  declare -A want=()
  for w in "${wanted[@]}"; do
    if ! [[ $w =~ $name_re ]] || [ -z "${c_exec[$w]+set}" ]; then
      die "no check named '$w' (assay check --list shows them)"
    fi
    if [ "${c_enable[$w]}" != 1 ]; then die "check '$w' is off in this repo"; fi
    if [ "$opt_fast" = 1 ] && [ "${c_fast[$w]}" != 1 ]; then die "check '$w' is not fast"; fi
    want[$w]=1
  done
  for n in "${names[@]}"; do
    if [ ${#wanted[@]} -gt 0 ]; then
      if [ -z "${want[$n]:-}" ]; then continue; fi
    else
      if [ "${c_enable[$n]}" != 1 ]; then continue; fi
      if [ "$opt_fast" = 1 ] && [ "${c_fast[$n]}" != 1 ]; then continue; fi
    fi
    selected+=("$n")
  done
}

root=
gitdir=
find_repo() {
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not in a git working tree"
  gitdir=$(git rev-parse --absolute-git-dir) || die "cannot find the git directory"
  cd "$root"
}

base_sha=
base_label=
base_source=
event_rev=

# The default branch: origin/HEAD's target, else origin/main, origin/master, main, master.
default_ref() {
  local r
  if r=$(git symbolic-ref -q refs/remotes/origin/HEAD) && git rev-parse -q --verify "$r^{commit}" >/dev/null; then
    echo "$r"
    return 0
  fi
  for r in refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
    if git rev-parse -q --verify "$r^{commit}" >/dev/null; then
      echo "$r"
      return 0
    fi
  done
  return 1
}

# GitHub's event: the pull request's base, or the commit before a push. Returns 1 when the event gives none (another
# event, or a push that created the branch, whose `before` is all zeros).
github_event_base() {
  local ev=$GITHUB_EVENT_PATH out
  if [ ! -f "$ev" ] || [ ! -r "$ev" ]; then die "cannot read GitHub's event $ev (GITHUB_EVENT_PATH)"; fi
  if ! out=$(jq -n -r 'input
      | (try .pull_request.base.sha catch null) as $pr
      | (try .before catch null) as $before
      | if ($pr | type) == "string" then "pull_request \($pr)"
        elif ($before | type) == "string" then "push \($before)"
        else "none" end' "$ev" 2>&1); then
    die "cannot read GitHub's event $ev: $out"
  fi
  case $out in
    "pull_request "*)
      event_rev=${out#* }
      base_source="pull_request event"
      ;;
    "push "*)
      event_rev=${out#* }
      if [[ $event_rev =~ ^0+$ ]]; then return 1; fi
      base_source="push event"
      ;;
    *) return 1 ;;
  esac
}

resolve_base() {
  local rev="" ref
  if [ "$opt_base_set" = 1 ]; then
    rev=$opt_base base_label=$opt_base base_source=--base
  elif [ -n "${ASSAY_BASE:-}" ]; then
    rev=$ASSAY_BASE base_label=$ASSAY_BASE base_source=ASSAY_BASE
  elif [ -n "${GITHUB_EVENT_PATH:-}" ] && github_event_base; then
    rev=$event_rev base_label=$event_rev
  fi
  if [ -n "$rev" ]; then
    base_sha=$(git rev-parse -q --verify --end-of-options "$rev^{commit}") ||
      die "base '$rev' (from $base_source) is not a commit in this clone, and assay never fetches:" \
        "fetch it first (in CI, actions/checkout with fetch-depth: 0)"
    return 0
  fi
  ref=$(default_ref) ||
    die "no base for the change: none of origin/HEAD, origin/main, origin/master, main or master exists;" \
      "pass --base <rev>"
  base_label=${ref#refs/remotes/}
  base_label=${base_label#refs/heads/}
  if base_sha=$(git merge-base --fork-point "$ref" HEAD 2>/dev/null); then
    base_source=fork-point
  elif base_sha=$(git merge-base "$ref" HEAD 2>/dev/null); then
    base_source=merge-base
  else
    die "no base for the change: HEAD shares no commit with $base_label; pass --base <rev>"
  fi
}

# requires_met <glob>: some file git sees in the working tree (tracked or untracked, not ignored) matches the glob,
# relative to the repo root.
requires_met() {
  local f list=$gitdir/assay/requires.tmp
  git ls-files -z --cached --others --exclude-standard -- ":(top,glob)$1" >"$list" ||
    die "cannot match '$1' against the working tree"
  while IFS= read -r -d '' f; do
    if [ -e "$f" ] || [ -L "$f" ]; then return 0; fi
  done <"$list"
  return 1
}

now_us() { now=${EPOCHREALTIME//[!0-9]/}; }
# fmt_secs <var> <microseconds>
fmt_secs() { printf -v "$1" '%d.%02ds' $(($2 / 1000000)) $(($2 % 1000000 / 10000)); }

plural() { if [ "$1" -eq 1 ]; then echo "$1 check"; else echo "$1 checks"; fi; }

# shell_word <string>: the string as one word for bash and zsh alike, quoted only when it needs it.
shell_word() {
  local q="'\\''"
  if [[ $1 =~ ^[A-Za-z0-9._/@:+=-]+$ ]]; then echo "$1"; else echo "'${1//\'/$q}'"; fi
}

run_checks() {
  local logdir=$gitdir/assay n log rc t0 now secs start i shown what
  local -a skipped=() failed=()
  declare -A is_skipped=() code=()
  mkdir -p "$logdir" 2>/dev/null || die "cannot create $logdir"
  [ -w "$logdir" ] || die "cannot write to $logdir"

  for n in "${selected[@]}"; do
    if [ -n "${c_requires[$n]}" ] && ! requires_met "${c_requires[$n]}"; then
      skipped+=("$n")
      is_skipped[$n]=1
    fi
  done
  rm -f "$logdir/requires.tmp"

  # Header: the mode and the base, then the loosenings and the skipped checks.
  local mode="assay check"
  if [ "$opt_fast" = 1 ]; then mode+=" --fast"; fi
  if [ ${#wanted[@]} -gt 0 ]; then mode+=" ${selected[*]}"; fi
  base_short=$(git rev-parse --short "$base_sha")
  if [[ $base_sha == "$base_label"* ]]; then shown=$base_short; else shown=$base_label@$base_short; fi
  echo "$mode · base $shown ($base_source)"
  for i in "${!loose_check[@]}"; do
    case ${loose_kind[$i]} in
      off) what="is off" ;;
      exec) what="runs the repo's own exec" ;;
    esac
    echo "  loosening: ${loose_check[$i]} $what: ${loose_reason[$i]//$'\n'/ }"
  done
  for n in "${skipped[@]}"; do
    echo "  skipped: $n (no ${c_requires[$n]})"
  done

  now_us
  start=$now
  for n in "${selected[@]}"; do
    log=$logdir/$n.log
    if [ -n "${is_skipped[$n]:-}" ]; then
      rm -f "$log"
      echo "skip $n (no ${c_requires[$n]})"
      continue
    fi
    now_us
    t0=$now
    rc=0
    PATH=$caller_path ASSAY_BASE=$base_sha "$BASH" -c "${c_exec[$n]}" </dev/null >"$log" 2>&1 || rc=$?
    now_us
    fmt_secs secs $((now - t0))
    if [ "$rc" -eq 0 ]; then
      echo "ok   $n $secs"
    else
      failed+=("$n")
      code[$n]=$rc
      if [ "$rc" -eq 127 ]; then
        echo "FAIL $n $secs (exit 127: tool not found)"
      else
        echo "FAIL $n $secs (exit $rc)"
      fi
    fi
  done
  now_us
  fmt_secs secs $((now - start))

  # Each failure: its command, the first 100 lines of its output, and the path of its full log.
  local lines
  for n in "${failed[@]}"; do
    log=$logdir/$n.log
    lines=$(wc -l <"$log")
    if [ -n "$(tail -c 1 "$log")" ]; then lines=$((lines + 1)); fi
    echo
    echo "--- FAIL $n (exit ${code[$n]})"
    echo "\$ ${c_exec[$n]}"
    if [ "$lines" -eq 0 ]; then
      echo "(no output)"
    else
      head -n 100 "$log"
      if [ -n "$(tail -c 1 "$log")" ] && [ "$lines" -le 100 ]; then echo; fi
      if [ "$lines" -gt 100 ]; then echo "[$((lines - 100)) more lines in the log]"; fi
    fi
    echo "log: $log"
  done

  # The last line: the count, and the command that reruns the failures.
  local last rerun
  if [ ${#failed[@]} -gt 0 ]; then
    rerun="assay check"
    if [ "$opt_base_set" = 1 ]; then rerun+=" --base $(shell_word "$opt_base")"; fi
    rerun+=" ${failed[*]}"
    last="${#failed[@]} of $(plural ${#selected[@]}) failed in $secs; rerun: $rerun"
    echo
  elif [ ${#selected[@]} -eq 0 ]; then
    last="no checks to run"
  else
    last="$(plural ${#selected[@]}) passed"
    if [ ${#skipped[@]} -gt 0 ]; then last+=" (${#skipped[@]} skipped)"; fi
    last+=" in $secs"
  fi
  if [ "$opt_fast" = 1 ] && [ $((now - start)) -gt $((fast_budget * 1000000)) ]; then
    last+=" (over the fast set's ${fast_budget}s budget)"
  fi
  echo "$last"
  if [ ${#failed[@]} -gt 0 ]; then finish 1; fi
  finish 0
}

cmd_check() {
  while [ $# -gt 0 ]; do
    case $1 in
      --fast) opt_fast=1 ;;
      --list) opt_list=1 ;;
      --base)
        [ $# -ge 2 ] || usage_error "--base needs a revision"
        opt_base=$2 opt_base_set=1
        shift
        ;;
      --base=*) opt_base=${1#--base=} opt_base_set=1 ;;
      -h | --help)
        usage_text
        finish 0
        ;;
      --)
        shift
        wanted+=("$@")
        break
        ;;
      -*) usage_error "unknown option '$1'" ;;
      *) wanted+=("$1") ;;
    esac
    shift
  done
  if [ "$opt_base_set" = 1 ] && [ -z "$opt_base" ]; then usage_error "--base needs a revision"; fi
  if [ "$opt_list" = 1 ] && { [ "$opt_fast" = 1 ] || [ "$opt_base_set" = 1 ] || [ ${#wanted[@]} -gt 0 ]; }; then
    usage_error "--list takes no other argument"
  fi

  local t
  for t in git jq head tail wc mkdir rm; do
    command -v "$t" >/dev/null || die "cannot find $t on the PATH"
  done
  load_config
  if [ "$opt_list" = 1 ]; then
    list_checks
    finish 0
  fi
  select_checks
  find_repo
  resolve_base
  run_checks
}

main() {
  [ $# -ge 1 ] || usage
  case $1 in
    check)
      shift
      cmd_check "$@"
      ;;
    -h | --help | help)
      usage_text
      finish 0
      ;;
    *) usage_error "unknown command '$1'" ;;
  esac
}

main "$@"
