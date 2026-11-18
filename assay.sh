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

Outside the repo's devenv (ASSAY_CONFIG unset), assay check runs itself inside it, from the repo root:
devenv shell -- assay check, so the version the repo pins decides.
The base of the change: --base, else ASSAY_BASE, else GitHub's event (GITHUB_EVENT_PATH), else the
fork point of HEAD from the default branch, else their merge base. assay never fetches.
Exit codes: 0 every selected check passed, 1 at least one failed, 2 assay could not run.
EOF
}

# The procedure a repo follows to adopt assay, named by the error for a repo that has not.
adoption_doc=https://github.com/eff3ct0/assay/blob/main/docs/adoption.md

# Every exit goes through these, so that any other exit (an unexpected failure under `set -e`) becomes exit 2 and
# never passes for a run's 0 or 1.
exiting=
finish() {
  exiting=1
  log_run "$1"
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
# Temporary files and directories, removed on exit.
tmp_paths=()
# tmp_file <var> [-d] [<template>]: a new temporary file (or directory, with -d), removed on exit, its path in <var>.
tmp_file() {
  local -n tmp_var=$1
  shift
  tmp_var=$(mktemp "$@") || die "cannot create a temporary file"
  tmp_paths+=("$tmp_var")
}
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
  local rc=$?
  if [ ${#tmp_paths[@]} -gt 0 ]; then rm -rf -- "${tmp_paths[@]}"; fi
  if [ -z "$exiting" ] && [ "$rc" -ne 0 ]; then
    echo "assay: unexpected failure (exit $rc)" >&2
    finish 2
  fi
}
trap on_exit EXIT
trap 'echo >&2; finish 130' INT TERM

# assay's own git calls never fetch, not even the missing objects of a partial clone. Checks don't see this function.
git() { GIT_NO_LAZY_FETCH=1 command git "$@"; }

# The hits log: one JSON object per line, appended to ASSAY_HITS_LOG only when it is set. Every source writes
# through log_hit <source> <filter> [<jq option>...]: the fields every line has (v, time, source, repo, agent), then
# the source's own, which the jq filter builds from the jq options given. Best-effort: a failure writes nothing,
# prints nothing and changes no exit code.
log_hit() {
  local source=$1 filter=$2 common repo="" line
  shift 2
  [ -n "${ASSAY_HITS_LOG:-}" ] || return 0
  {
    # The main checkout, the same from any of its worktrees: the parent of the common git directory.
    if common=$(git rev-parse --path-format=absolute --git-common-dir); then repo=${common%/.git}; fi
    line=$(jq -nc --arg source "$source" --arg repo "$repo" --arg agent "${ASSAY_AGENT:-}" "$@" '
      def text_or_null: if . == "" then null else . end;
      {v: 1, time: (now | todate), source: $source, repo: ($repo | text_or_null), agent: ($agent | text_or_null)}
      + ('"$filter"')') &&
      mkdir -p "$(dirname "$ASSAY_HITS_LOG")" &&
      printf '%s\n' "$line" >>"$ASSAY_HITS_LOG"
  } 2>/dev/null || true
}

# When `assay check` started a run: set once its arguments parsed into one (not --list). A run, passing or not,
# writes one check line to the hits log when it exits, whatever its exit code.
run_start=
log_run() {
  [ -n "$run_start" ] || return 0
  local now secs mode=full i
  local -a args=()
  now_us
  fmt_secs secs $((now - run_start))
  run_start=
  if [ "$opt_fast" = 1 ]; then mode=fast; fi
  args=(--arg mode "$mode" --arg seconds "${secs%s}" --arg exit "$1")
  # Each name goes in an option of its own, only<i> or failed<i>: the names given may hold any character.
  for i in "${!wanted[@]}"; do args+=(--arg "only$i" "${wanted[$i]}"); done
  for i in "${!failed[@]}"; do args+=(--arg "failed$i" "${failed[$i]}"); done
  # shellcheck disable=SC2016 # jq's $variables, not the shell's
  log_hit check '
    def names($list):
      [$ARGS.named | to_entries[] | {i: (.key | capture("^\($list)(?<i>[0-9]+)$").i | tonumber), value}]
      | sort_by(.i) | map(.value);
    {mode: $mode, only: names("only"), seconds: ($seconds | tonumber), failed: names("failed"), exit: ($exit | tonumber)}
  ' "${args[@]}"
}

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

# Only ever called with ASSAY_CONFIG set: without it, main delegates.
load_config() {
  local cfg=$ASSAY_CONFIG out
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
failed=()

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

# New code: the lines a change adds or modifies, from the base's tree to the working tree, untracked files included.
# `suppressions` reads it here, and the `findings` check reuses it.

# change_diff <base>: the change as `git diff -U0` prints it, through a copy of the index that adds the untracked
# files (not the ignored ones) as intent-to-add, so that they count as added. Renames are followed; binary files and
# submodules show no lines. Every option that a user's configuration could change is fixed, so that the same tree
# and base give the same diff anywhere. A path is quoted, C-style, only when it holds a control character, `"` or `\`.
change_diff() {
  local index untracked objects store
  tmp_file index
  tmp_file untracked
  # Intent-to-add writes the empty blob: objects git writes go to a throwaway store, the repo's own an alternate.
  tmp_file objects -d
  store=$(git rev-parse --path-format=absolute --git-path objects) || die "cannot find the object store"
  cp -- "$(git rev-parse --git-path index)" "$index" 2>/dev/null || rm -f -- "$index"
  git ls-files -z --others --exclude-standard >"$untracked" || die "cannot list the untracked files"
  if [ -s "$untracked" ]; then
    GIT_INDEX_FILE=$index GIT_OBJECT_DIRECTORY=$objects GIT_ALTERNATE_OBJECT_DIRECTORIES=$store \
      git --literal-pathspecs add --intent-to-add --pathspec-from-file="$untracked" --pathspec-file-nul ||
      die "cannot add the untracked files to a copy of the index"
  fi
  GIT_INDEX_FILE=$index GIT_OBJECT_DIRECTORY=$objects GIT_ALTERNATE_OBJECT_DIRECTORIES=$store \
    git -c core.quotePath=false diff -U0 --inter-hunk-context=0 --histogram -M --no-relative --no-color \
    --no-ext-diff --no-textconv --ignore-submodules=all --src-prefix=a/ --dst-prefix=b/ "$1" ||
    die "cannot diff the working tree against the base $1"
}

# Reads change_diff's output. Prints "<first>\t<last>\t<path>" for each hunk that adds lines (the path as git prints
# it, quoted or not). With the variable `removed` set to a file name, also writes "<path>\t<text>" there for each line
# the change removes, under the file's new path (its old one when the file is deleted).
# shellcheck disable=SC2016 # awk's $0, not the shell's
diff_awk='
function path_of(p, prefix) {
  sub(/\t$/, "", p)
  if (p == "/dev/null") return ""
  if (substr(p, 1, 1) == "\"") return "\"" substr(p, 2 + length(prefix))
  return substr(p, 1 + length(prefix))
}
old > 0 || new > 0 {
  c = substr($0, 1, 1)
  if (c == "-") { old--; if (removed != "") print path "\t" substr($0, 2) > removed; next }
  if (c == "+") { new--; next }
  if (c == "\\") next
  old = 0; new = 0
}
/^diff --git / { from = ""; path = ""; to = ""; next }
/^--- / { from = path_of(substr($0, 5), "a/"); next }
/^\+\+\+ / { to = path_of(substr($0, 5), "b/"); path = (to == "") ? from : to; next }
/^@@ / {
  split($0, f, " ")
  n = split(substr(f[2], 2), o, ","); old = (n > 1) ? o[2] + 0 : 1
  n = split(substr(f[3], 2), w, ","); new = (n > 1) ? w[2] + 0 : 1
  if (new > 0 && to != "") printf "%d\t%d\t%s\n", w[1], w[1] + new - 1, to
}
'

# new_code <diff file>: the new code in a diff from change_diff, as NUL-terminated records: a path, then the first
# and the last line of one of its ranges. A file's ranges come in order.
new_code() {
  local first last path
  LC_ALL=C awk "$diff_awk" "$1" | while IFS=$'\t' read -r first last path; do
    if [[ $path == \"*\" ]]; then
      path=${path:1:${#path}-2}
      path=${path//%/%%}
      # shellcheck disable=SC2059 # the format decodes git's C-style quoting
      printf -v path -- "$path"
    fi
    printf '%s\0%s\0%s\0' "$path" "$first" "$last"
  done
}

cmd_new_code() {
  parse_base_option new-code "$@"
  find_repo
  resolve_base
  local diff
  tmp_file diff
  change_diff "$base_sha" >"$diff"
  new_code "$diff" | jq -S -R -s 'split("\u0000") | .[:-1] as $f
    | reduce range(0; $f | length; 3) as $i ({}; .[$f[$i]] += [[($f[$i + 1] | tonumber), ($f[$i + 2] | tonumber)]])'
  finish 0
}

# The built-in checks that are assay's own code, run as `assay builtin <check>`.

# root_entry <commit> <name>: one entry at the repo root, from the working tree (<commit> empty) or from a commit's
# tree. Sets entry_type (missing, file, symlink or other) and entry_content (a file's bytes, a symlink's target).
root_entry() {
  local rev=$1 name=$2 line mode oid
  entry_type=missing entry_content=
  if [ -z "$rev" ]; then
    if [ -L "$name" ]; then
      entry_type=symlink
      entry_content=$(readlink -- "$name") || die "cannot read the symlink $name"
    elif [ -f "$name" ]; then
      entry_type="file"
      entry_content=$(cat -- "$name" && echo .) || die "cannot read $name"
      entry_content=${entry_content%.}
    elif [ -e "$name" ]; then
      entry_type=other
    fi
    return 0
  fi
  line=$(git ls-tree --full-tree "$rev" -- "$name") || die "cannot read the tree of $rev"
  [ -n "$line" ] || return 0
  mode=${line%% *}
  oid=${line#* * }
  oid=${oid%%$'\t'*}
  case $mode in
    100644 | 100755)
      entry_type="file"
      entry_content=$(git cat-file blob "$oid" && echo .) || die "cannot read $name in $rev"
      entry_content=${entry_content%.}
      ;;
    120000)
      entry_type=symlink
      entry_content=$(git cat-file blob "$oid") || die "cannot read $name in $rev"
      ;;
    *) entry_type=other ;;
  esac
}

# has_related_repos <markdown>: the text has a "Related repos" heading, of any level and case.
has_related_repos() {
  local line
  while IFS= read -r line; do
    if [[ ${line,,} =~ ^#{1,6}[[:space:]]+related[[:space:]]+repos[[:space:]#]*$ ]]; then return 0; fi
  done <<<"$1"
  return 1
}

# agents_md_problems [<commit>]: the AGENTS.md / CLAUDE.md shape at the repo root (the current directory), in the
# working tree or in a commit's tree, which the global pre-push hook reads for each pushed tip. AGENTS.md holds the
# instructions, with a "Related repos" section, and CLAUDE.md is the single line @AGENTS.md; or either file is a
# symlink to the other, which holds them. Prints one line per problem and returns 1 when there is any.
agents_md_problems() {
  local rev=${1:-} a_type a_content c_type c_content a_to_c=0 c_to_a=0 instructions="" text
  local -a problems=()
  root_entry "$rev" AGENTS.md
  a_type=$entry_type a_content=$entry_content
  root_entry "$rev" CLAUDE.md
  c_type=$entry_type c_content=$entry_content
  if [ "$a_type" = symlink ]; then case $a_content in CLAUDE.md | ./CLAUDE.md) a_to_c=1 ;; esac; fi
  if [ "$c_type" = symlink ]; then case $c_content in AGENTS.md | ./AGENTS.md) c_to_a=1 ;; esac; fi

  case $a_type in
    missing) problems+=("AGENTS.md is missing: it holds the repo's instructions for every agent") ;;
    other) problems+=("AGENTS.md is not a file: it holds the repo's instructions for every agent") ;;
  esac
  case $c_type in
    missing) problems+=("CLAUDE.md is missing: make it the single line @AGENTS.md") ;;
    other) problems+=("CLAUDE.md is not a file: make it the single line @AGENTS.md") ;;
  esac
  if [ "$a_to_c" = 1 ] && [ "$c_to_a" = 1 ]; then
    problems+=("AGENTS.md and CLAUDE.md are symlinks to each other: AGENTS.md holds the instructions, and CLAUDE.md is the single line @AGENTS.md")
  elif [ "$a_to_c" = 1 ]; then
    case $c_type in
      file) instructions=CLAUDE.md text=$c_content ;;
      symlink) problems+=("CLAUDE.md is a symlink to $c_content, and AGENTS.md a symlink to CLAUDE.md: CLAUDE.md holds the instructions itself") ;;
    esac
  elif [ "$a_type" = symlink ]; then
    problems+=("AGENTS.md is a symlink to $a_content: it holds the instructions itself, or is a symlink to CLAUDE.md")
  elif [ "$a_type" = file ]; then
    instructions=AGENTS.md text=$a_content
    if [ "$c_type" = symlink ] && [ "$c_to_a" = 0 ]; then
      problems+=("CLAUDE.md is a symlink to $c_content: make it the single line @AGENTS.md, or a symlink to AGENTS.md")
    elif [ "$c_type" = file ] && [ "$c_content" != @AGENTS.md ] && [ "$c_content" != $'@AGENTS.md\n' ]; then
      if [ "$c_content" = "$a_content" ]; then
        problems+=("CLAUDE.md copies AGENTS.md: a copy falls short, even an identical one; make CLAUDE.md the single line @AGENTS.md")
      else
        problems+=("CLAUDE.md is neither the single line @AGENTS.md nor a symlink to AGENTS.md: move its instructions into AGENTS.md, then make it the single line @AGENTS.md")
      fi
    fi
  fi
  if [ -n "$instructions" ] && ! has_related_repos "$text"; then
    problems+=("$instructions has no \"Related repos\" section: add one naming the repos this one depends on and the repos that depend on it, with what passes between them, or saying there are none")
  fi
  [ ${#problems[@]} -gt 0 ] || return 0
  printf '%s\n' "${problems[@]}"
  return 1
}

builtin_agents_md() {
  local rev=
  [ $# -le 1 ] || usage_error "agents-md takes at most one commit"
  find_repo
  if [ $# -eq 1 ]; then
    rev=$(git rev-parse -q --verify --end-of-options "$1^{commit}") || die "agents-md: '$1' is not a commit"
  fi
  if agents_md_problems "$rev"; then finish 0; fi
  finish 1
}

# commit-trailers: no commit in base..HEAD carries a Co-Authored-By trailer, matched case-insensitively on any line
# of its message, as GitHub reads one.
builtin_commit_trailers() {
  local re='^[[:space:]]*co-authored-by[[:space:]]*:' list commit subject line base_short
  parse_base_option commit-trailers "$@"
  find_repo
  resolve_base
  list=$(git log --no-show-signature -i -E --grep="$re" --format='%H %h %s' "$base_sha..HEAD") ||
    die "cannot read the commits in $base_sha..HEAD"
  [ -n "$list" ] || finish 0
  base_short=$(git rev-parse --short "$base_sha")
  echo "Co-Authored-By trailers in $base_short..HEAD:"
  while IFS=' ' read -r commit subject; do
    echo "  $subject"
    while IFS= read -r line; do
      if [[ ${line,,} =~ $re ]]; then echo "      ${line#"${line%%[![:space:]]*}"}"; fi
    done < <(git log -1 --no-show-signature --format=%B "$commit")
  done <<<"$list"
  echo "A commit names no co-author: reword each of these without its trailer (git rebase -i $base_short)," \
    "and push with --force-with-lease where they were pushed."
  finish 1
}

cmd_builtin() {
  [ $# -ge 1 ] || usage_error "builtin needs the name of a built-in check"
  local check=$1
  shift
  case $check in
    agents-md) builtin_agents_md "$@" ;;
    commit-trailers) builtin_commit_trailers "$@" ;;
    *) usage_error "no built-in check named '$check'" ;;
  esac
}

# parse_base_option <command> [--base <rev>]: the arguments of a command whose only option is --base.
parse_base_option() {
  local command=$1
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --base)
        [ $# -ge 2 ] || usage_error "--base needs a revision"
        opt_base=$2 opt_base_set=1
        shift
        ;;
      --base=*) opt_base=${1#--base=} opt_base_set=1 ;;
      *) usage_error "$command: unexpected argument '$1'" ;;
    esac
    shift
  done
  if [ "$opt_base_set" = 1 ] && [ -z "$opt_base" ]; then usage_error "--base needs a revision"; fi
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
  local -a skipped=()
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
  if [ "$opt_list" = 0 ]; then
    now_us
    run_start=$now
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

# not_adopted <why>: exit 2 for a repo that has not adopted assay, naming the procedure.
not_adopted() {
  {
    echo "assay: this repo has not adopted assay: $*"
    echo "assay: adopting it is a change of its own, on its own branch and pull request, made before any other" \
      "work in the repo; tell the user about it before starting"
    echo "assay: the procedure: $adoption_doc"
  } >&2
  finish 2
}

# What the delegating assay runs inside the repo's devenv: it records in the directory given first whether the
# devenv set ASSAY_CONFIG (assay's module does) and whether it handed over, then runs the repo's own assay. Being
# the delegating assay's own code, it works whatever version of assay the repo pins.
# shellcheck disable=SC2016 # expanded by the bash that runs it
delegate_sh='tmp=$1
shift
if [ -z "${ASSAY_CONFIG:-}" ]; then
  : >"$tmp/unadopted"
  exit 2
fi
: >"$tmp/started"
exec assay "$@"'

# delegate <command> [<arg>...]: outside the repo's devenv, run `assay <command> <arg>...` inside it, from the repo
# root, so that the version the repo pins decides. devenv runs with the caller's PATH, not assay's own tools.
delegate() {
  local rc=0
  find_repo
  [ -f "$root/devenv.nix" ] || not_adopted "$root has no devenv.nix"
  PATH=$caller_path command -v devenv >/dev/null ||
    die "cannot find devenv on the PATH, which assay needs to run inside the repo's devenv"
  local delegate_tmp
  tmp_file delegate_tmp -d
  PATH=$caller_path devenv shell -- "$BASH" -c "$delegate_sh" assay "$delegate_tmp" "$@" || rc=$?
  if [ -e "$delegate_tmp/unadopted" ]; then not_adopted "the devenv of $root does not import assay's module"; fi
  # devenv itself failed (exit 1 on an evaluation error), which must not pass for a failing check.
  [ -e "$delegate_tmp/started" ] || die "devenv shell failed (exit $rc) before assay could run in the repo's devenv"
  case $rc in
    0 | 1 | 2 | 130) finish "$rc" ;;
    *) die "the repo's assay exited $rc" ;;
  esac
}

# not_yet <command> <usage>: a subcommand a later version implements.
not_yet() {
  echo "usage: assay $1 $2" >&2
  die "$1 is not implemented yet"
}

main() {
  [ $# -ge 1 ] || usage
  case $1 in
    check)
      shift
      if [ -z "${ASSAY_CONFIG:-}" ]; then delegate check "$@"; fi
      cmd_check "$@"
      ;;
    builtin)
      shift
      if [ -z "${ASSAY_CONFIG:-}" ]; then delegate builtin "$@"; fi
      cmd_builtin "$@"
      ;;
    new-code)
      shift
      if [ -z "${ASSAY_CONFIG:-}" ]; then delegate new-code "$@"; fi
      cmd_new_code "$@"
      ;;
    # The machine-level subcommands run outside any devenv and never delegate.
    guard) not_yet guard "--rules <file>    the agent guard: one harness hook event on stdin" ;;
    git-hook) not_yet git-hook "--rules <file> <hook> [<git args>]    the global git hooks" ;;
    collect) not_yet collect "--db <file>    the nightly collector" ;;
    -h | --help | help)
      usage_text
      finish 0
      ;;
    *) usage_error "unknown command '$1'" ;;
  esac
}

main "$@"
