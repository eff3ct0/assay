#!/usr/bin/env bash
# assay: a repo's named checks, declared in its devenv through assay's devenv module (devenv/) and run the same way
# from pre-commit, `devenv test` and an agent's `devenv shell`. The module hands the checks over as one JSON file
# whose path is ASSAY_CONFIG.
set -euo pipefail

# The package sets assay_tools (git, jq, gawk, coreutils) on the line before this script. assay's own commands find them
# first; each check runs with the PATH assay was called with, so it sees the devenv's tools, not assay's.
caller_path=$PATH
if [ -n "${assay_tools:-}" ]; then PATH=$assay_tools:$PATH; fi

# The whole fast set's budget, in seconds, with a warm cache. Going over it fails nothing.
fast_budget=5
# Check names become log file names.
name_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
# qlty's smells, which the configuration's findings.smells may set.
smell_kinds='["boolean_logic", "file_complexity", "function_complexity", "function_parameters", "identical_code",
  "nested_control_flow", "return_statements", "similar_code"]'

usage_text() {
  cat <<'EOF'
usage: assay check [--fast] [--base <rev>] [<check>...]    run the repo's checks
       assay check --list                                  list them, fast ones marked
       assay builtin agents-md [<commit>]                  one of the built-in checks that are assay's own code
       assay builtin commit-trailers [--base <rev>]
       assay builtin gitleaks
       assay builtin suppressions [--base <rev>]
       assay builtin findings [--base <rev>]
       assay findings [--base <rev>] [--sarif]             the analyzer's findings on the change
       assay new-code [--base <rev>]                       the change's new code, as JSON

Outside the repo's devenv (ASSAY_CONFIG unset), these run themselves inside it, from the repo root:
devenv shell -- assay <command>, so the version the repo pins decides.
The base of the change: --base, else ASSAY_BASE, else GitHub's event (GITHUB_EVENT_PATH), else the
fork point of HEAD from the default branch, else their merge base. assay never fetches.
Exit codes: 0 every selected check passed, 1 at least one failed, 2 assay could not run;
assay builtin exits 127 when the tool its check runs is missing; assay findings exits 0
whenever it ran, with findings or without.
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
  elif .kind == "setting" then
    # A setting of the analyzer, which names the check it feeds; a hand-written configuration may leave it out.
    if (.check | text | not) then fail("a loosening of a setting names no check")
    elif (.what | text | not) then fail("loosening of a setting of \(.check) does not say what it is")
    elif (.reason | text | not) then fail("loosening of \(.check) has no reason")
    else . end
  elif (.check | type) != "string" or (.check as $k | $checks | has($k) | not) then fail("loosening of an unknown check \(.check | tojson)")
  elif (.kind | IN("off", "exec") | not) then fail("loosening of \(.check): unknown kind \(.kind | tojson)")
  elif (.reason | text | not) then fail("loosening of \(.check) has no reason")
  else . end;
def positive: type == "number" and . >= 1 and . == floor;
def smell_ok:
  type == "object" and (.enable | type) == "boolean" and (.threshold | positive);
def findings_ok:
  if . == null then .
  elif type != "object" then fail("findings must be an object")
  elif (.radarlint // [] | type != "array" or any(.[]; IN("python", "scala") | not)) then
    fail("findings.radarlint must list python or scala")
  elif (.rules // {} | type != "object" or any(to_entries[]; (.key | test("^[a-z]+:[A-Za-z0-9_-]+$") | not) or (.value | type) != "boolean")) then
    fail("findings.rules must map Sonar rule keys (python:S3776) to true or false")
  elif (.smells // {} | type != "object" or any(to_entries[]; (.key | IN($smells[]) | not) or (.value | smell_ok | not))) then
    fail("findings.smells must map qlty smells (\($smells | join(", "))) to {enable, threshold}, a positive integer")
  elif .duplication != null and (.duplication | type != "object" or (.nodes_threshold | positive | not)) then
    fail("findings.duplication.nodes_threshold must be a positive integer")
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
    | ($c.findings | findings_ok)
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
  (.loosenings[] | "loose_check+=(\(.check | @sh)) loose_kind+=(\(.kind | @sh)) loose_reason+=(\(.reason | @sh))"
    + " loose_what+=(\(.what // "" | @sh))"),
  "config_loaded=1"
'

names=()
declare -A c_exec=() c_fast=() c_enable=() c_requires=()
loose_check=()
loose_kind=()
loose_reason=()
loose_what=()
config_loaded=0

# Only ever called with ASSAY_CONFIG set: without it, main delegates.
load_config() {
  local cfg=$ASSAY_CONFIG out
  if [ ! -f "$cfg" ] || [ ! -r "$cfg" ]; then die "cannot read the configuration $cfg (ASSAY_CONFIG)"; fi
  if ! out=$(jq -n -r --arg name_re "$name_re" --argjson smells "$smell_kinds" "$config_jq" "$cfg" 2>&1); then
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
# submodules show no lines. Every option that a user's configuration could change is fixed (renames are looked for
# without git's limit on their number), so that the same tree and base give the same diff anywhere. A path is
# quoted, C-style, only when it holds a control character, `"` or `\`.
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
    git -c core.quotePath=false diff -U0 --inter-hunk-context=0 --histogram -M -l0 -O/dev/null --no-relative \
    --no-color --no-ext-diff --no-textconv --ignore-submodules=all --src-prefix=a/ --dst-prefix=b/ "$1" ||
    die "cannot diff the working tree against the base $1"
}

# Reads change_diff's output. Prints "<first>\t<last>\t<path>" for each hunk that adds lines (the path as git prints
# it, quoted or not). With the variable `removed` set to a file name, also writes "<path>\t<text>" there for each line
# the change removes, under the file's new path (its old one when the file is deleted). With the variable `renames`
# set to a file name, writes "<old path>\t<new path>" there for each renamed file, the paths as git prints them.
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
/^rename from / { renamed = substr($0, 13); next }
/^rename to / { if (renames != "") print renamed "\t" substr($0, 11) > renames; next }
/^--- / { from = path_of(substr($0, 5), "a/"); next }
/^\+\+\+ / { to = path_of(substr($0, 5), "b/"); path = (to == "") ? from : to; next }
/^@@ / {
  split($0, f, " ")
  n = split(substr(f[2], 2), o, ","); old = (n > 1) ? o[2] + 0 : 1
  n = split(substr(f[3], 2), w, ","); new = (n > 1) ? w[2] + 0 : 1
  if (new > 0 && to != "") printf "%d\t%d\t%s\n", w[1], w[1] + new - 1, to
}
'

# git_unquote <var>: the path in <var>, as git prints it, with git's C-style quoting undone.
git_unquote() {
  local -n unquote_var=$1
  if [[ $unquote_var == \"*\" ]]; then
    unquote_var=${unquote_var:1:${#unquote_var}-2}
    unquote_var=${unquote_var//%/%%}
    # shellcheck disable=SC2059 # the format decodes git's C-style quoting
    printf -v unquote_var -- "$unquote_var"
  fi
}

# new_code <diff file> [<removed file>]: the new code in a diff from change_diff, as NUL-terminated records: a path,
# then the first and the last line of one of its ranges. A file's ranges come in order. With a second file, the
# lines the change removes are written there too, as diff_awk writes them.
new_code() {
  local first last path
  LC_ALL=C awk -v removed="${2:-}" "$diff_awk" "$1" | while IFS=$'\t' read -r first last path; do
    git_unquote path
    printf '%s\0%s\0%s\0' "$path" "$first" "$last"
  done
}

# new_code_json <diff file>: the new code in a diff from change_diff, as one JSON object, {"<path>": [[first, last],
# ...]}, keys sorted.
new_code_json() {
  new_code "$1" | jq -S -R -s 'split("\u0000") | .[:-1] as $f
    | reduce range(0; $f | length; 3) as $i ({}; .[$f[$i]] += [[($f[$i + 1] | tonumber), ($f[$i + 2] | tonumber)]])'
}

# renames_json <diff file>: the files a diff from change_diff renames, as one JSON object, {"<new path>": "<old path>"}.
renames_json() {
  local list from to
  tmp_file list
  LC_ALL=C awk -v renames="$list" "$diff_awk" "$1" >/dev/null
  while IFS=$'\t' read -r from to; do
    git_unquote from
    git_unquote to
    printf '%s\0%s\0' "$to" "$from"
  done <"$list" | jq -R -s 'split("\u0000") | .[:-1] as $f | reduce range(0; $f | length; 2) as $i ({}; .[$f[$i]] = $f[$i + 1])'
}

cmd_new_code() {
  parse_base_option new-code "$@"
  find_repo
  resolve_base
  local diff
  tmp_file diff
  change_diff "$base_sha" >"$diff"
  new_code_json "$diff"
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

# has_related_repos <markdown>: the text has a "Related repos" heading, of any level and case, outside fenced code.
has_related_repos() {
  local line fenced=0
  while IFS= read -r line; do
    if [[ $line =~ ^\ {0,3}('```'|'~~~') ]]; then fenced=$((1 - fenced)); fi
    if [ "$fenced" = 0 ] && [[ ${line,,} =~ ^#{1,6}[[:space:]]+related[[:space:]]+repos[[:space:]#]*$ ]]; then return 0; fi
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
    elif [ "$c_type" = file ] && [ "$c_content" != @AGENTS.md ] && [ "$c_content" != $'@AGENTS.md\n' ] &&
      [ "$c_content" != $'@AGENTS.md\r\n' ]; then
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

# gitleaks: gitleaks over the files git sees in the working tree (tracked, or untracked but not ignored), not over
# history. `gitleaks dir` reads ignored files too (.devenv/, a local .env), so it scans a hard-linked copy of the
# files git sees (a plain copy where hard links fail), from that copy's root: the paths it reports, the fingerprints
# in .gitleaksignore and the repo's .gitleaks.toml work as from the repo root. Secrets are redacted.
builtin_gitleaks() {
  local copy list report f i rc=0 count
  local -a files=()
  [ $# -eq 0 ] || usage_error "gitleaks takes no argument"
  find_repo
  if ! command -v gitleaks >/dev/null; then
    echo "assay: cannot find gitleaks on the PATH" >&2
    finish 127
  fi
  mkdir -p "$gitdir/assay" || die "cannot create $gitdir/assay"
  tmp_file copy -d "$gitdir/assay/gitleaks.XXXXXX"
  tmp_file list
  tmp_file report
  git ls-files -z --cached --others --exclude-standard --deduplicate >"$list" || die "cannot list the working tree"
  while IFS= read -r -d '' f; do
    # A deleted tracked file is gone, and a directory is a submodule or a nested repo.
    if [ -L "$f" ] || [ -f "$f" ]; then files+=("$root/$f"); fi
  done <"$list"
  [ ${#files[@]} -gt 0 ] || finish 0
  # copy_files <cp option>...: every file at its absolute path under the copy, symlinks as symlinks.
  copy_files() {
    for ((i = 0; i < ${#files[@]}; i += 1000)); do
      cp "$@" -P --parents -t "$copy" -- "${files[@]:i:1000}" || return 1
    done
  }
  if ! copy_files --link 2>/dev/null; then
    { rm -rf "$copy" && mkdir "$copy"; } || die "cannot recreate $copy"
    copy_files --reflink=auto || die "cannot copy the working tree's files to $copy"
  fi
  (cd "$copy$root" && gitleaks dir --no-banner --no-color --redact --log-level error --exit-code 0 \
    --report-format json --report-path "$report" .) || rc=$?
  if [ "$rc" -ne 0 ]; then
    die "gitleaks failed (exit $rc)"
  fi
  count=$(jq length "$report") || die "cannot read gitleaks's report"
  [ "$count" -gt 0 ] || finish 0
  jq -r 'sort_by(.File, .StartLine, .RuleID)[] | "\(.File):\(.StartLine): \(.RuleID) (fingerprint \(.Fingerprint))"' \
    "$report"
  if [ "$count" -eq 1 ]; then echo -n "gitleaks found 1 secret"; else echo -n "gitleaks found $count secrets"; fi
  echo " in the working tree: remove each one, and rotate it if it ever left this machine; a false positive's" \
    "fingerprint goes in .gitleaksignore."
  finish 1
}

# suppressions: a new suppression on new code names the rule it silences and gives a reason. The markers are known
# per language, which a file's extension gives (a shell script's shebang too, when it has none). A marker with a
# reason field must give the reason there; one without takes a comment on the same line or a comment line just
# above. A suppression the change also removes from the same file (the same marker and rules on a removed line: a
# modified or a moved line) is not new.
#
# Inputs, in this order: the removed lines ("<path>\t<text>", from diff_awk), the new code ("<n>\t<first>\t<last>",
# <n> being the position of the file among those that follow) and the files that hold new code, each as ./<path>.
# Prints each new suppression that falls short as "<path>:<line>: <problem>" with the line under it, then a count;
# exits 1 when there is any.
# shellcheck disable=SC2016 # awk's $0, not the shell's
suppressions_awk='
BEGIN {
  for (i = 3; i < ARGC; i++) position[ARGV[i]] = i - 2
  form["noqa"] = "# noqa: E501  # <why>"
  form["ruff: noqa"] = "# ruff: noqa: E501  # <why>"
  form["flake8: noqa"] = "# flake8: noqa: E501  # <why>"
  form["type: ignore"] = "# type: ignore[attr-defined]  # <why>"
  form["pyright: ignore"] = "# pyright: ignore[reportAttributeAccessIssue]  # <why>"
  form["pragma: no cover"] = "# pragma: no cover  # <why>"
  form["pragma: no branch"] = "# pragma: no branch  # <why>"
  form["shellcheck disable"] = "# shellcheck disable=SC2086 # <why>"
  form["@ts-expect-error"] = "// @ts-expect-error TS2345: <why>"
  form["Stryker disable"] = "// Stryker disable next-line EqualityOperator: <why>"
  form["#[allow]"] = "#[allow(clippy::too_many_lines, reason = \"<why>\")]"
  form["#![allow]"] = "#![allow(dead_code, reason = \"<why>\")]"
  form["#[expect]"] = "#[expect(clippy::too_many_lines, reason = \"<why>\")]"
  form["#![expect]"] = "#![expect(dead_code, reason = \"<why>\")]"
  form["#[mutants::skip]"] = "#[mutants::skip] // <why>"
  form["@nowarn"] = "@nowarn(\"cat=deprecation\") // <why>"
  form["@SuppressWarnings"] = "@SuppressWarnings(Array(\"org.wartremover.warts.Var\")) // <why>"
  form["scalafix:off"] = "// scalafix:off DisableSyntax.var; <why>"
  form["scalafix:ok"] = "// scalafix:ok DisableSyntax.var; <why>"
  split("a b t n v f r", names, " ")
  for (i = 1; i <= 7; i++) escaped[names[i]] = sprintf("%c", i + 6)
  escaped["\""] = "\""; escaped["\\"] = "\\"
  bad = 0
}

# The language of a file, by its extension; "none" for a file that has none.
function ext_lang(p,   b, e) {
  b = p
  sub(/.*\//, "", b)
  if (!match(b, /.\.[^.]+$/)) return "none"
  e = tolower(substr(b, RSTART + 2))
  if (e ~ /^(js|jsx|mjs|cjs|ts|tsx|mts|cts|vue|svelte)$/) return "js"
  if (e ~ /^(py|pyi)$/) return "py"
  if (e == "rs") return "rs"
  if (e ~ /^(scala|sc|sbt)$/) return "scala"
  if (e ~ /^(sh|bash|bats)$/) return "sh"
  return ""
}
function shebang_lang(first) {
  return (first ~ /^#![ \t]*[^ \t]*\/(env[ \t]+(-[^ \t]+[ \t]+)*)?((ba|da|k)?sh|bats)([ \t]|$)/) ? "sh" : ""
}
# A path as diff_awk gives it, which git quotes C-style when it holds a control character, `"` or `\`.
function unquote(p,   out, i, c) {
  if (p !~ /^".*"$/) return p
  p = substr(p, 2, length(p) - 2)
  out = ""
  for (i = 1; i <= length(p); i++) {
    c = substr(p, i, 1)
    if (c == "\\") {
      c = substr(p, ++i, 1)
      if (c ~ /[0-7]/) {
        c = sprintf("%c", substr(p, i, 1) * 64 + substr(p, i + 1, 1) * 8 + substr(p, i + 2, 1))
        i += 2
      } else if (c in escaped) c = escaped[c]
    }
    out = out c
  }
  return out
}
# The language of a removed line, by the path of its file.
function removed_lang(p,   l, first) {
  l = ext_lang(p)
  if (l != "none") return l
  if (!(p in shebang_of)) {
    first = ""
    if ((getline first < p) > 0) shebang_of[p] = shebang_lang(first); else shebang_of[p] = ""
    close(p)
  }
  return shebang_of[p]
}

function has_text(s) { return s ~ /[^[:space:][:punct:]]/ }
# A comment line with text, in the language.
function comment_line(lang, s) {
  if (lang == "py" || lang == "sh") {
    if (s !~ /^[ \t]*#/ || s ~ /^[ \t]*#!/) return 0
    match(s, /#/)
  } else if (!match(s, /^[ \t]*(\/\/|\/\*|\*)/)) return 0
  return has_text(substr(s, RSTART + RLENGTH))
}
# A comment with text in what is left of a line once its markers are cut out.
function trailing_comment(lang, w) {
  if (lang == "py" || lang == "sh") { if (!match(w, /#/)) return 0 }
  else if (!match(w, /\/\/|\/\*/)) return 0
  return has_text(substr(w, RSTART + RLENGTH))
}
function squeeze(s) { gsub(/[ \t:]+/, "", s); return s }
# The body of a comment that starts at the end of the match: up to its "*/", or the end.
function body(w, from,   s) {
  s = substr(w, from)
  if (match(s, /\*\//)) s = substr(s, 1, RSTART - 1)
  return s
}

# add(M, label, key, named, reason, field): one marker found by scan. reason: given in its field, or (without a field)
# in a comment on the same line, which scan settles once every marker of the line is cut out.
function add(M, label, key, named, reason, field,   j) {
  j = ++M["n"]
  M[j, "label"] = label; M[j, "key"] = label ":" key; M[j, "named"] = named
  M[j, "reason"] = reason; M[j, "field"] = field; M[j, "banned"] = ""
}
# cut(w): w with the last match blanked out, so that it is not found again and is no comment of its own.
function cut(w, len) { return substr(w, 1, RSTART - 1) " " substr(w, RSTART + (len ? len : RLENGTH)) }

# qlty-ignore, in the comment syntax of the language: qlty-ignore: <tool:rule>..., or qlty-ignore(<tool:rule>...):
# <why>. Specs that all start with "-" end a region and are no suppression.
function scan_qlty(M, w, delim,   s, specs, why, at, len, named) {
  while (match(w, "(" delim ")[ \t]*qlty-ignore")) {
    at = RSTART; len = RLENGTH
    s = body(w, at + len)
    why = ""
    if (match(s, /^[ \t]*\([^)]*\)/)) {
      specs = substr(s, RSTART, RLENGTH); why = substr(s, RSTART + RLENGTH)
      gsub(/[()]/, "", specs)
      if (!sub(/^[ \t]*:/, "", why)) why = ""
    } else {
      specs = s; sub(/^[ \t]*:/, "", specs)
    }
    RSTART = at
    w = cut(w, len + length(s))
    if (specs ~ /^[ \t,]*(-[^ \t,]+[ \t,]*)+$/) continue
    named = (specs ~ /(^|[ \t,])[+>]?[a-z0-9_.-]+[:\/][^ \t,]/)
    add(M, "qlty-ignore", squeeze(specs), named, has_text(why), 1)
  }
  return w
}

# scan(lang, s, M): the suppressions in s, into M (see add). Returns how many.
function scan(lang, s, M,   w, t, at, len, rules, why, label, j, k, same, c) {
  M["n"] = 0
  w = tolower(s)
  if (lang == "py") {
    while (match(w, /#[ \t]*((ruff|flake8)[ \t]*:[ \t]*)?noqa([ \t]*:[ \t]*[a-z]+[0-9]+([ \t]*,?[ \t]*[a-z]+[0-9]+)*)?/)) {
      t = substr(w, RSTART, RLENGTH); w = cut(w)
      label = (t ~ /ruff[ \t]*:/) ? "ruff: noqa" : (t ~ /flake8[ \t]*:/) ? "flake8: noqa" : "noqa"
      rules = t; sub(/.*noqa/, "", rules)
      add(M, label, squeeze(rules), squeeze(rules) != "", 0, 0)
    }
    while (match(w, /#[ \t]*(type|pyright):[ \t]*ignore(\[[^]]*\])?/)) {
      t = substr(w, RSTART, RLENGTH); w = cut(w)
      label = (t ~ /pyright/) ? "pyright: ignore" : "type: ignore"
      rules = t; sub(/^[^[]*/, "", rules); gsub(/[][]/, "", rules)
      add(M, label, squeeze(rules), has_text(rules), 0, 0)
    }
    while (match(w, /#[ \t]*pragma:[ \t]*no[ \t]+(cover|branch)/)) {
      t = substr(w, RSTART, RLENGTH); w = cut(w)
      label = (t ~ /cover/) ? "pragma: no cover" : "pragma: no branch"
      add(M, label, "", 1, 0, 0)
    }
    w = scan_qlty(M, w, "#")
  } else if (lang == "sh") {
    while (match(w, /#[ \t]*shellcheck[ \t]+([a-z]+=[^ \t]*[ \t]+)*disable=[^ \t]*/)) {
      t = substr(w, RSTART, RLENGTH); w = cut(w)
      rules = t; sub(/.*disable=/, "", rules)
      add(M, "shellcheck disable", rules, has_text(rules) && ("," rules ",") !~ /,all,/, 0, 0)
    }
  } else if (lang == "js") {
    while (match(w, /(\/\/|\/\*)[ \t]*(eslint|oxlint)-disable(-next-line|-line)?/)) {
      at = RSTART; len = RLENGTH
      t = substr(w, at, len); label = t; sub(/^[^a-z]*/, "", label)
      c = substr(w, at + len, 1)
      if (c != "" && c != " " && c != "\t" && c != "*") { w = cut(w); continue }
      rules = body(w, at + len); RSTART = at; w = cut(w, len + length(rules))
      why = ""
      if (match(rules, /--+/)) { why = substr(rules, RSTART + RLENGTH); rules = substr(rules, 1, RSTART - 1) }
      add(M, label, squeeze(rules), rules ~ /[a-z0-9@]/, has_text(why), 1)
    }
    while (match(w, /(\/\/|\/\*)[ \t]*@ts-(ignore|nocheck|expect-error)/)) {
      at = RSTART; len = RLENGTH
      t = substr(w, at, len); label = t; sub(/^[^@]*/, "", label)
      why = body(w, at + len); RSTART = at; w = cut(w, len + length(why))
      if (label == "@ts-expect-error") {
        rules = ""
        while (match(why, /ts[0-9]+/)) { rules = rules "," substr(why, RSTART, RLENGTH); why = cut(why) }
        add(M, label, rules, rules != "", has_text(why), 1)
        continue
      }
      add(M, label, "", 0, 0, 1)
      j = M["n"]
      if (label == "@ts-ignore")
        M[j, "banned"] = "@ts-ignore is not allowed; use @ts-expect-error, which fails once the error is gone, like: " form["@ts-expect-error"]
      else
        M[j, "banned"] = "@ts-nocheck silences the whole file; fix its errors, or silence each one like: " form["@ts-expect-error"]
    }
    while (match(w, /(\/\/|\/\*)[ \t]*stryker[ \t]+disable/)) {
      at = RSTART; len = RLENGTH
      rules = body(w, at + len); RSTART = at; w = cut(w, len + length(rules))
      why = ""
      if (match(rules, /:/)) { why = substr(rules, RSTART + 1); rules = substr(rules, 1, RSTART - 1) }
      sub(/^[ \t]*(next-line|line)([ \t]|$)/, "", rules)
      add(M, "Stryker disable", squeeze(rules), has_text(rules) && (" " rules " ") !~ /[ \t,]all[ \t,]/, has_text(why), 1)
    }
    w = scan_qlty(M, w, "\\/\\/|\\/\\*")
  } else if (lang == "rs") {
    while (match(w, /#!?\[[ \t]*(allow|expect)[ \t]*\(/)) {
      at = RSTART; len = RLENGTH
      t = substr(w, at, len); label = (t ~ /!/ ? "#![" : "#[") (t ~ /allow/ ? "allow" : "expect") "]"
      rules = substr(w, at + len)
      if (match(rules, /\)[ \t]*\]/)) rules = substr(rules, 1, RSTART - 1)
      RSTART = at; w = cut(w, len + length(rules))
      why = ""
      if (match(rules, /reason[ \t]*=[ \t]*"[^"]*"/)) {
        why = substr(rules, RSTART, RLENGTH); sub(/^[^"]*"/, "", why)
        rules = cut(rules)
      }
      add(M, label, squeeze(rules), rules ~ /[a-z_]/, has_text(why), 1)
    }
    while (match(w, /#\[[ \t]*mutants::skip[ \t]*\]/)) {
      w = cut(w)
      add(M, "#[mutants::skip]", "", 1, 0, 0)
    }
    w = scan_qlty(M, w, "\\/\\/|\\/\\*")
  } else if (lang == "scala") {
    while (match(w, /@nowarn([ \t]*\([^)]*\))?/)) {
      t = substr(w, RSTART, RLENGTH); w = cut(w)
      rules = t; sub(/^@nowarn/, "", rules)
      add(M, "@nowarn", squeeze(rules), rules ~ /"[^"]*[^"[:space:]][^"]*"/, 0, 0)
    }
    while (match(w, /@suppresswarnings[ \t]*(\(([^()]|\([^()]*\))*\))?/)) {
      t = substr(w, RSTART, RLENGTH); w = cut(w)
      rules = t; sub(/^@suppresswarnings/, "", rules)
      add(M, "@SuppressWarnings", squeeze(rules), rules ~ /"[^"]*[^"[:space:]][^"]*"/, 0, 0)
    }
    while (match(w, /\/\/[ \t]*scalafix:(off|ok)/)) {
      at = RSTART; len = RLENGTH
      t = substr(w, at, len); label = t; sub(/^[^s]*/, "", label)
      rules = substr(w, at + len); RSTART = at; w = cut(w, len + length(rules))
      why = ""
      if (match(rules, /;/)) { why = substr(rules, RSTART + 1); rules = substr(rules, 1, RSTART - 1) }
      add(M, label, squeeze(rules), has_text(rules), has_text(why), 1)
    }
    w = scan_qlty(M, w, "\\/\\/|\\/\\*")
  }
  # A marker without a reason field takes its reason from a comment left on the line.
  same = trailing_comment(lang, w)
  for (k = 1; k <= M["n"]; k++) if (!M[k, "field"]) M[k, "reason"] = same
  return M["n"]
}

function isnew(n, ln) {
  while (ptr <= count[n] && last[n, ptr] + 0 < ln) ptr++
  return ptr <= count[n] && first[n, ptr] + 0 <= ln
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }

FILENAME == ARGV[1] {
  t = index($0, "\t")
  path = unquote(substr($0, 1, t - 1))
  lang = removed_lang(path)
  if (lang != "") for (k = scan(lang, substr($0, t + 1), R); k > 0; k--) base[path, R[k, "key"]]++
  next
}
FILENAME == ARGV[2] {
  split($0, r, "\t")
  n = r[1]; count[n]++; first[n, count[n]] = r[2]; last[n, count[n]] = r[3]
  next
}
FNR == 1 {
  n = position[FILENAME]; name = substr(FILENAME, 3); ptr = 1; prev = ""
  lang = ext_lang(name)
  if (lang == "none") lang = shebang_lang($0)
}
lang == "" { next }
{
  line = $0; at = FNR; text = $0; fresh = isnew(n, FNR); w = tolower($0)
  # An attribute or a block comment over several lines is read whole; it is new when any of its lines is.
  if ((lang == "rs" && w ~ /#!?\[[ \t]*(allow|expect)[ \t]*\(/ && w !~ /\)[ \t]*\]/) ||
      (lang == "js" && w ~ /\/\*[ \t]*(eslint|oxlint)-disable/ && w !~ /\/\*[ \t]*(eslint|oxlint)-disable.*\*\//)) {
    nxt = $0
    for (j = 0; j < 50 && (getline nxt) > 0; j++) {
      text = text " " nxt
      if (isnew(n, FNR)) fresh = 1
      if ((lang == "rs" && nxt ~ /\)[ \t]*\]/) || (lang == "js" && nxt ~ /\*\//)) break
    }
    $0 = nxt
  }
  above = prev
  prev = $0
  if (!fresh || scan(lang, text, M) == 0) next
  checked_above = 0
  for (k = 1; k <= M["n"]; k++) {
    reason = M[k, "reason"]
    if (!reason && !M[k, "field"]) {
      if (!checked_above) { above_ok = comment_line(lang, above) && scan(lang, above, A) == 0; checked_above = 1 }
      reason = above_ok
    }
    if (M[k, "banned"] == "" && M[k, "named"] && reason) continue
    if (base[name, M[k, "key"]] > 0) { base[name, M[k, "key"]]--; continue }
    label = M[k, "label"]
    if (M[k, "banned"] != "") msg = M[k, "banned"]
    else if (!M[k, "named"] && !reason) msg = label " names no rule and gives no reason; write it like: " form_of(label) (M[k, "field"] ? "" : " (or with the reason in a comment on the line above)")
    else if (!M[k, "named"]) msg = label " names no rule; name the one it silences, like: " form_of(label)
    else msg = label " gives no reason; give one, like: " form_of(label) (M[k, "field"] ? "" : " (or in a comment on the line above)")
    printf "%s:%d: %s\n    %s\n", name, at, msg, trim(line)
    bad++
  }
}
function form_of(label) {
  if (label in form) return form[label]
  if (label == "qlty-ignore") return (lang == "py" ? "# " : "// ") "qlty-ignore(eslint:camelcase): <why>"
  return "// " label " no-console -- <why>"
}
END {
  if (bad == 0) exit 0
  printf "%d new suppression%s short: each one names the rule it silences and gives a reason.\n", bad, (bad == 1 ? " falls" : "s fall")
  exit 1
}
'

builtin_suppressions() {
  local diff removed ranges path first last n=0 rc=0
  local -a files=()
  local -A position=()
  parse_base_option suppressions "$@"
  find_repo
  resolve_base
  tmp_file diff
  tmp_file removed
  tmp_file ranges
  change_diff "$base_sha" >"$diff"
  while IFS= read -r -d '' path && IFS= read -r -d '' first && IFS= read -r -d '' last; do
    if [ -z "${position[$path]+set}" ]; then
      if [ -L "$path" ] || [ ! -f "$path" ]; then continue; fi
      n=$((n + 1))
      position[$path]=$n
      files+=("./$path")
    fi
    printf '%s\t%s\t%s\n' "${position[$path]}" "$first" "$last"
  done < <(new_code "$diff" "$removed") >"$ranges"
  [ "$n" -gt 0 ] || finish 0
  LC_ALL=C awk "$suppressions_awk" "$removed" "$ranges" "${files[@]}" || rc=$?
  case $rc in
    0 | 1) finish "$rc" ;;
    *) die "cannot read the files that hold new code (awk exit $rc)" ;;
  esac
}

# The analyzer. `assay findings` runs qlty in the repo itself, with no server: `qlty check`, whose findings qlty keeps to
# the changed lines, and `qlty smells`, which reports every smell of a changed file. qlty runs only what no other
# check runs: radarlint's plugins, for Python and Scala, and smells, for TypeScript, Rust, Python and Scala. The
# built-in `findings` check fails on the new findings among those `assay findings` shows.

# .qlty/qlty.toml, from the configuration's `findings` settings (qlty's own defaults for what it leaves out), with
# radarlint's plugins pointed at $radarlint, an absolute path: qlty runs plugins with an empty PATH, and would
# download its own tools for its own plugin definitions.
# shellcheck disable=SC2016 # jq's $variables and qlty's ${target}, not the shell's
findings_toml_jq='
(.findings // {}) as $f
| "# Written by assay on every run, from assay.findings: an edit here does not last.",
  "config_version = \"0\"",
  (($f.smells // {}) | to_entries[] | "", "[smells.\(.key)]", "enabled = \(.value.enable)", "threshold = \(.value.threshold)"),
  # One value per repo, not per language: Rust has its own in qlty'"'"'s defaults.
  (if $f.duplication then "", "[smells.duplication]", "nodes_threshold = \($f.duplication.nodes_threshold)",
     "", "[language.rust]", "smells.duplication.nodes_threshold = \($f.duplication.nodes_threshold)" else empty end),
  (($f.radarlint // [])[] as $language | "radarlint-\($language)" as $plugin
    | "", "[plugins.definitions.\($plugin)]", "file_types = [\($language | tojson)]",
      "config_files = [\"radarlint.properties\"]", "latest_version = \"assay\"", "known_good_version = \"assay\"",
      "", "[plugins.definitions.\($plugin).drivers.lint]",
      "script = \("\($radarlint | @sh) \($language) ${target}" | tojson)", "success_codes = [0, 1]", "output = \"stdout\"",
      "output_format = \"sarif\"", "output_missing = \"error\"", "batch = true", "cache_results = true"),
  (($f.radarlint // [])[] | "", "[[plugin]]", "name = \("radarlint-\(.)" | tojson)", "version = \"assay\"")
'

# .qlty/configs/radarlint.properties, which radarlint reads from the directory it runs in: qlty links it into the repo
# root while radarlint runs. A rule python:S3776 is radarlint.rules.python.S3776.
radarlint_properties_jq='(.findings.rules // {}) | to_entries[] | "radarlint.rules.\(.key | sub(":"; "."))=\(.value)"'

# What both programs over qlty's SARIF need. A path is a URI there, percent-encoded, non-ASCII characters included.
# shellcheck disable=SC2016 # jq's $variables, not the shell's
sarif_defs='
def utf8_string:
  . as $b | length as $n
  | def code($i):
      if $i >= $n then empty
      else $b[$i] as $c
        | if $c < 128 then $c, code($i + 1)
          elif $c >= 240 then ($c % 8) * 262144 + ($b[$i + 1] % 64) * 4096 + ($b[$i + 2] % 64) * 64 + $b[$i + 3] % 64, code($i + 4)
          elif $c >= 224 then ($c % 16) * 4096 + ($b[$i + 1] % 64) * 64 + $b[$i + 2] % 64, code($i + 3)
          elif $c >= 192 then ($c % 32) * 64 + $b[$i + 1] % 64, code($i + 2)
          else $c, code($i + 1) end
      end;
    [code(0)] | implode;
def hex: ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | .[0] * 16 + .[1];
def uri_path:
  if test("%") then [match("%[0-9A-Fa-f]{2}|[^%]|%"; "g").string | if length == 3 then .[1:] | hex else explode[0] end] | utf8_string
  else . end;
def place: .locations[0].physicalLocation;
def path: place.artifactLocation.uri // "" | uri_path;
def line: place.region.startLine // 0;
def last_line: [line, place.region.endLine // 0] | max;
# A linter'"'"'s finding is about a place in the code; a smell, about a piece of it: a function, a file, a block, an
# expression or a clone.
def about_a_place($run): $run == "lint";
def clone: .ruleId | IN("qlty:identical-code", "qlty:similar-code");
'

# The findings on the change as one SARIF log, {"runs": [lint, smells]}, each result marked new or not with SARIF's
# baselineState. A linter'"'"'s finding is new when any of its lines is new code, as qlty keeps them to changed lines. A
# smell is new when the base has no counterpart: the same rule, file (through renames) and function (a block's or an
# expression'"'"'s, none: the same rule and file); for a clone'"'"'s place, a clone'"'"'s place in the same file, between the same
# files. So a smell the base has, grown or edited, is not new. qlty'"'"'s hash of a clone is no identity: a clone grows or
# shrinks to the largest piece of code its places share, so an unrelated edit next to one changes it. With more of one
# counterpart now than at the base, the ones that do not start on new code take the base'"'"'s first.
# shellcheck disable=SC2016 # jq's $variables, not the shell's
findings_jq='
($config[0].findings.rules // {}) as $rules
| $new_code[0] as $new_code | $renames[0] as $renames
| def in_smell_languages: (place.region.sourceLanguage // "") | IN("python", "rust", "scala", "tsx", "typescript");
  def rule_on: ($rules[.ruleId // "" | sub("^[^:]*:"; "")]) != false;
  def new_code($from; $to): path as $p | any($new_code[$p][]?; .[0] <= $to and $from <= .[1]);
  def on_new_code($run): if about_a_place($run) then new_code(line; last_line) else new_code(line; line) end;
  def function: .message.text // "" | capture("\\(count = [0-9]+\\): (?<name>.*)$").name // "";
  def counterpart($paths):
    path as $p
    | if clone then ["clone", ($paths[$p] // $p),
        ([place, .relatedLocations[]?.physicalLocation] | map(.artifactLocation.uri // "" | uri_path | $paths[.] // .) | unique)]
      else [.ruleId, ($paths[$p] // $p), function] end
    | tojson;
  def results: [.[0].runs[]?.results[]?];
  ($lint | results | map(select(rule_on) | . + {baselineState: (if on_new_code("lint") then "new" else "unchanged" end)}))
    as $lint_results
| ($base | results | map(select(in_smell_languages) | counterpart({}))
    | reduce .[] as $k ({}; .[$k] += 1)) as $base_counts
| ($smells | results | map(select(in_smell_languages)) | to_entries
    | map({i: .key, result: .value, on_new_code: (.value | on_new_code("smells")),
        key: (.value | counterpart($renames))})) as $entries
| (reduce ($entries | group_by(.key)[]) as $group ({};
      ($base_counts[$group[0].key] // 0) as $at_base
      | reduce ($group | sort_by(.on_new_code, (.result | line)) | to_entries[]) as $e (.;
          .[$e.value.i | tostring] = (if $e.key < $at_base then "unchanged" else "new" end)))) as $states
| ($entries | map(.result + {baselineState: $states[.i | tostring]})) as $smells_results
| {"$schema": "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json",
   version: "2.1.0",
   runs: [($lint[0].runs[0] + {results: $lint_results}), ($smells[0].runs[0] + {results: $smells_results})]}
'

# The text of a findings log: by file, a blank line between files; in a file the lint findings, then the smells, by
# line, as "<path>:<line>: <tool>/<rule>: <message>", a clone followed by its places. With $only_new, the new ones
# only, and nothing at all without any.
# shellcheck disable=SC2016 # jq's $variables, not the shell's
findings_text_jq='
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";
def where: "\(.artifactLocation.uri // "" | uri_path):\(.region.startLine)-\(.region.endLine // .region.startLine)";
[.runs | to_entries[] | (if .key == 0 then "lint" else "smells" end) as $run | .key as $order | .value.results[]?
  | {path: path, line: line, order: $order, rule: (.ruleId // "" | sub(":"; "/")), new: (.baselineState == "new"),
     about_a_place: about_a_place($run),
     message: ((.message.text // "" | gsub("[\\r\\n\\t]+"; " "))
       + (if clone then ": " + ([place, .relatedLocations[]?.physicalLocation] | map(where) | join(", ")) else "" end))}]
| if $only_new then map(select(.new)) else . end
| (map(select(.new)) | length) as $new_count
| (group_by(.path)
    | map(sort_by(.order, .line, .rule)
        | map("\(.path):\(.line): \(.rule): \(.message)"
            + if .new or $only_new then "" elif .about_a_place then " (not on new code)" else " (at the base too)" end)
        | join("\n"))
    | join("\n\n")) as $body
| length as $all
| if $only_new then
    if $new_count == 0 then empty
    else $body, "", "\(plural($new_count; "new finding")) on the change: fix each one (assay findings shows them among the rest)"
    end
  elif $all == 0 then "no findings on the change"
  else $body, "", "\(plural($all; "finding")) on the change, "
    + if $new_count == 0 then "none new: the findings check passes"
      else "\($new_count) of them new: the findings check fails on those" end
  end
'

radarlint_bin=
tool_missing=
# findings_tools: qlty on the PATH, and radarlint when the configuration runs it, whose absolute path goes in
# radarlint_bin. Returns 1, with the message in tool_missing, when one is missing.
findings_tools() {
  local languages
  if ! command -v qlty >/dev/null; then
    tool_missing="cannot find qlty on the PATH"
    return 1
  fi
  languages=$(jq -r '.findings.radarlint // [] | join(" and ")' "$ASSAY_CONFIG") || die "cannot read $ASSAY_CONFIG"
  [ -n "$languages" ] || return 0
  if ! radarlint_bin=$(command -v radarlint) || ! radarlint_bin=$(readlink -f -- "$radarlint_bin"); then
    tool_missing="cannot find radarlint on the PATH, which the findings run for $languages"
    return 1
  fi
}

# findings_prepare: .qlty/ kept out of git through .git/info/exclude, then .qlty/qlty.toml and
# .qlty/configs/radarlint.properties written from the configuration, as on every run.
findings_prepare() {
  local exclude
  if git ls-files --error-unmatch -- .qlty/qlty.toml >/dev/null 2>&1; then
    die "the repo tracks .qlty/qlty.toml, which assay writes on every run from assay.findings: move its settings" \
      "there and remove the file from git"
  fi
  exclude=$(git rev-parse --path-format=absolute --git-path info/exclude) || die "cannot find .git/info/exclude"
  if ! grep -qxF .qlty/ "$exclude" 2>/dev/null; then
    {
      mkdir -p "$(dirname "$exclude")" &&
        if [ -s "$exclude" ] && [ -n "$(tail -c 1 "$exclude")" ]; then echo >>"$exclude"; fi &&
        echo .qlty/ >>"$exclude"
    } || die "cannot add .qlty/ to $exclude"
  fi
  mkdir -p .qlty/configs || die "cannot create .qlty/configs"
  jq -r --arg radarlint "$radarlint_bin" "$findings_toml_jq" "$ASSAY_CONFIG" >.qlty/qlty.toml ||
    die "cannot write .qlty/qlty.toml"
  jq -r "$radarlint_properties_jq" "$ASSAY_CONFIG" >.qlty/configs/radarlint.properties ||
    die "cannot write .qlty/configs/radarlint.properties"
}

# run_qlty <out> <what> <dir> <arg>...: qlty with its arguments, from <dir>, with telemetry off and no update check;
# its SARIF log goes to <out>. A failure, or anything but a SARIF log, is exit 2 with qlty's own message.
run_qlty() {
  local out=$1 what=$2 dir=$3 err rc=0
  shift 3
  tmp_file err
  (
    cd "$dir" || exit 2
    # Elsewhere than in the repo, git's variables would name the repo instead.
    if [ "$dir" != . ]; then unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; fi
    QLTY_TELEMETRY=off exec qlty --no-upgrade-check "$@"
  ) >"$out" 2>"$err" || rc=$?
  if [ "$rc" -eq 0 ] && jq -e '.runs | type == "array"' "$out" >/dev/null 2>&1; then return 0; fi
  {
    grep -v '^[[:space:]]*$' "$err" | tail -n 20
    jq -r '.runs[]?.invocations[]?.toolExecutionNotifications[]?.message.text' "$out" 2>/dev/null
  } >&2
  if [ "$rc" -ne 0 ]; then die "$what failed (exit $rc)"; fi
  die "$what printed no SARIF log"
}

# findings_base_smells <out> <path>...: qlty's smells about those files of the base, in a copy of the base's tree
# (qlty needs a git repository: an empty one will do). A path the base does not have is left out.
findings_base_smells() {
  local out=$1 index copy p
  local -a present=()
  shift
  tmp_file index
  tmp_file copy -d
  rm -f -- "$index"
  GIT_INDEX_FILE=$index git read-tree "$base_sha" || die "cannot read the tree of the base $base_sha"
  GIT_INDEX_FILE=$index git checkout-index -a -f --prefix="$copy/" || die "cannot copy the base's tree to $copy"
  for p in "$@"; do
    if [ -f "$copy/$p" ] && [ ! -L "$copy/$p" ]; then present+=("$p"); fi
  done
  if [ ${#present[@]} -eq 0 ]; then
    echo '{"runs": []}' >"$out"
    return 0
  fi
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$copy" init --quiet || die "cannot create a repository in $copy"
  { mkdir -p "$copy/.qlty" && cp .qlty/qlty.toml "$copy/.qlty/qlty.toml"; } || die "cannot write $copy/.qlty/qlty.toml"
  run_qlty "$out" "qlty smells at the base" "$copy" smells --sarif --quiet -- "${present[@]}"
}

# findings_sarif <out>: the findings on the change, as findings_jq writes them, to <out>.
findings_sarif() {
  local out=$1 diff new renames lint smells base paths p
  local -a base_paths=()
  tmp_file diff
  tmp_file new
  tmp_file renames
  tmp_file lint
  tmp_file smells
  tmp_file base
  tmp_file paths
  findings_prepare
  change_diff "$base_sha" >"$diff"
  new_code_json "$diff" >"$new"
  renames_json "$diff" >"$renames"
  run_qlty "$lint" "qlty check" . check --upstream "$base_sha" --sarif --no-progress --no-fail --no-formatters \
    --level note
  run_qlty "$smells" "qlty smells" . smells --upstream "$base_sha" --sarif --quiet
  # The base's paths of the files whose smells need a counterpart.
  jq -j --slurpfile renames "$renames" "$sarif_defs"'
    [.runs[]?.results[]? | path] | unique[] | ($renames[0][.] // .) + "\u0000"' \
    "$smells" >"$paths" || die "cannot read qlty's smells"
  while IFS= read -r -d '' p; do base_paths+=("$p"); done <"$paths"
  if [ ${#base_paths[@]} -gt 0 ]; then
    findings_base_smells "$base" "${base_paths[@]}"
  else
    echo '{"runs": []}' >"$base"
  fi
  jq -n --slurpfile config "$ASSAY_CONFIG" --slurpfile lint "$lint" --slurpfile smells "$smells" \
    --slurpfile base "$base" --slurpfile new_code "$new" --slurpfile renames "$renames" "$sarif_defs$findings_jq" >"$out" ||
    die "cannot match the findings against the base"
}

# findings_run <exit>: the findings on the change, as findings_sarif writes them, in the file findings_log names. A
# missing tool ends the run with that exit code and the tool's name.
findings_log=
findings_run() {
  load_config
  find_repo
  resolve_base
  if ! findings_tools; then
    echo "assay: $tool_missing" >&2
    finish "$1"
  fi
  tmp_file findings_log
  findings_sarif "$findings_log"
}

cmd_findings() {
  local sarif=0 arg
  local -a rest=()
  for arg in "$@"; do
    case $arg in
      --sarif) sarif=1 ;;
      -h | --help)
        usage_text
        finish 0
        ;;
      *) rest+=("$arg") ;;
    esac
  done
  parse_base_option findings "${rest[@]}"
  findings_run 2
  if [ "$sarif" = 1 ]; then
    jq . "$findings_log" || die "cannot print the SARIF log"
  else
    jq -r --argjson only_new false "$sarif_defs$findings_text_jq" "$findings_log" || die "cannot print the findings"
  fi
  finish 0
}

builtin_findings() {
  local text
  parse_base_option findings "$@"
  findings_run 127
  text=$(jq -r --argjson only_new true "$sarif_defs$findings_text_jq" "$findings_log") || die "cannot print the findings"
  [ -n "$text" ] || finish 0
  printf '%s\n' "$text"
  finish 1
}

cmd_builtin() {
  [ $# -ge 1 ] || usage_error "builtin needs the name of a built-in check"
  local check=$1
  shift
  case $check in
    agents-md) builtin_agents_md "$@" ;;
    commit-trailers) builtin_commit_trailers "$@" ;;
    gitleaks) builtin_gitleaks "$@" ;;
    suppressions) builtin_suppressions "$@" ;;
    findings) builtin_findings "$@" ;;
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
      setting) what=${loose_what[$i]} ;;
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
    findings)
      shift
      if [ -z "${ASSAY_CONFIG:-}" ]; then delegate findings "$@"; fi
      cmd_findings "$@"
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
