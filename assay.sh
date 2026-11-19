#!/usr/bin/env bash
# assay: a repo's named checks, declared in its devenv through assay's devenv module (devenv/) and run the same way
# from pre-commit, `devenv test` and an agent's `devenv shell`. The module hands the checks over as one JSON file
# whose path is ASSAY_CONFIG.
# A function called as a condition (the git wrapper below, and each predicate) runs without set -e: every one of them
# reports its own failure, through die or its status, and none relies on set -e.
# shellcheck disable=SC2310
set -euo pipefail

# The package sets assay_tools (git, jq, gawk, coreutils, ast-grep, yq) on the line before this script. assay's own
# commands find them first; each check runs with the PATH assay was called with, so it sees the devenv's tools, not
# assay's.
caller_path=$PATH
if [ -n "${assay_tools:-}" ]; then PATH=$assay_tools:$PATH; fi

# The whole fast set's budget, in seconds, with a warm cache. Going over it fails nothing.
fast_budget=5
# Check names become log file names.
name_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
# qlty's smells, which the configuration's findings.smells may set.
IFS= read -r -d '' smell_kinds <<'JSON' || true
["boolean_logic", "file_complexity", "function_complexity", "function_parameters", "identical_code",
  "nested_control_flow", "return_statements", "similar_code"]
JSON

usage_text() {
	cat <<'EOF'
usage: assay check [--fast] [--base <rev>] [<check>...]    run the repo's checks
       assay check --list                                  list them, fast and off ones marked
       assay preset [<language>...]                        write the languages' presets into the repo, or merge
                                                           newer versions in
       assay builtin agents-md [<commit>]                  one of the built-in checks that are assay's own code
       assay builtin ast-grep
       assay builtin commit-trailers [--base <rev>]
       assay builtin gitleaks
       assay builtin preset
       assay builtin suppressions [--base <rev>]
       assay builtin findings [--base <rev>]
       assay builtin tla
       assay findings [--base <rev>] [--sarif]             the analyzer's findings on the change
       assay new-code [--base <rev>]                       the change's new code, as JSON
       assay rule new <kebab-name> [--lang <lang>] [--from <file>:<line>[-<line>]]
                                                           scaffold an ast-grep rule and its tests
       assay guard --rules <file>                          the agent guard: one hook event on stdin
       assay git-hook --rules <file> <hook> [<git's arguments>]
                                                           a global git hook: commit-msg or pre-push

Outside the repo's devenv (ASSAY_CONFIG unset), check, preset, builtin, findings, new-code and rule
run themselves inside it: devenv shell -- assay <command>, so the version the repo pins decides.
guard and git-hook run where they are called, over the rule list given with --rules.
The base of the change: --base, else ASSAY_BASE, else GitHub's event (GITHUB_EVENT_PATH), else the
fork point of HEAD from the default branch, else their merge base. assay never fetches.
Exit codes: 0 every selected check passed, 1 at least one failed, 2 assay could not run;
assay preset exits 1 on a conflict or on a kept file that differs from the preset;
assay builtin exits 127 when the tool its check runs is missing, and assay rule new 1 when a rule of
that name already exists; assay findings exits 0 whenever it ran, with findings or without. assay
guard exits 0 with its answer on stdout, and 1 on its own error, which lets the call through; assay
git-hook exits 1 when a rule is violated or cannot be evaluated.
EOF
}

# The procedure a repo follows to adopt assay, named by the error for a repo that has not.
adoption_doc=https://github.com/eff3ct0/assay/blob/main/docs/adoption.md

# Every exit goes through these, so that any other exit (an unexpected failure under `set -e`) becomes exit 2 and
# never passes for a run's 0 or 1. The machine-level subcommands exit 1 instead (error_exit), and git-hook prefixes
# every error with what failing means for it (die_prefix).
exiting=
error_exit=2
die_prefix=
finish() {
	exiting=1
	log_run "$1"
	exit "$1"
}
die() {
	echo "assay: $die_prefix$*" >&2
	finish "$error_exit"
}
usage() {
	usage_text >&2
	finish "$error_exit"
}
usage_error() {
	echo "assay: $die_prefix$*" >&2
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
		echo "assay: ${die_prefix}unexpected failure (exit $rc)" >&2
		finish "$error_exit"
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
IFS= read -r -d '' config_jq <<'JQ' || true
def fail($m): "\($m)\n" | halt_error(1);
def text: type == "string" and length > 0;
def percent: type == "number" and . == floor and . >= 0 and . <= 100;
def check_ok($n):
  if type != "object" then fail("check \($n): not an object")
  elif (.exec | text | not) then fail("check \($n): exec must be a non-empty string")
  elif (.fast | type) != "boolean" then fail("check \($n): fast must be true or false")
  elif (.enable | type) != "boolean" then fail("check \($n): enable must be true or false")
  elif .requires != null and (.requires | text | not) then fail("check \($n): requires must be null or a non-empty string")
  elif .coverage != null and (.coverage | text | not) then fail("check \($n): coverage must be null or a non-empty string")
  else . end;
def loosening_ok($checks):
  if type != "object" then fail("a loosening is not an object")
  elif .kind == "new-code" then
    if (.newCode | percent | not) or (.default | percent | not) then fail("loosening of new code: newCode and default must be integers from 0 to 100")
    elif (.reason | text | not) then fail("loosening of new code has no reason")
    else . end
  elif .kind == "setting" then
    # A setting of the analyzer, which names the check it feeds; a hand-written configuration may leave it out.
    if (.check | text | not) then fail("a loosening of a setting names no check")
    elif (.what | text | not) then fail("loosening of a setting of \(.check) does not say what it is")
    elif (.reason | text | not) then fail("loosening of \(.check) has no reason")
    else . end
  elif (.check | type) != "string" or (.check as $k | $checks | has($k) | not) then fail("loosening of an unknown check \(.check | tojson)")
  elif (.kind | IN("off", "exec", "coverage") | not) then fail("loosening of \(.check): unknown kind \(.kind | tojson)")
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
  elif (.coverage != null or any(.checks[]; .coverage? != null))
    and ((.coverage | type) != "object" or (.coverage.newCode | percent | not))
  then fail("coverage.newCode must be an integer from 0 to 100")
  elif (.loosenings | type) != "array" then fail("loosenings must be an array")
  elif .languages != null and ((.languages | type) != "array" or
    any(.languages[]; if type == "string" then test("^[a-z][a-z0-9_-]*$") | not else true end)) then
    fail("languages must be an array of language names")
  elif .rulePacks != null and ((.rulePacks | type) != "object" or
    any(.rulePacks | to_entries[]; (.key | test($name_re) | not) or (.value | text | not))) then
    fail("rulePacks must map pack names to directories")
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
      "c_requires[\($n | @sh)]=\($c.requires // "" | @sh)",
      "c_coverage[\($n | @sh)]=\($c.coverage // "" | @sh)"),
  "new_code=\(.coverage.newCode // "")",
  (.loosenings[]
    | "loose_check+=(\(.check // "" | @sh)) loose_kind+=(\(.kind | @sh)) loose_reason+=(\(.reason | @sh))",
      "loose_value+=(\(if .kind == "new-code" then "\(.newCode) \(.default)" elif .kind == "setting" then .what
        else "" end | @sh))"),
  ((.languages // [])[] | "cfg_languages+=(\(@sh))"),
  ((.rulePacks // {}) | to_entries | sort_by(.key)[] | "pack_names+=(\(.key | @sh)) pack_dirs+=(\(.value | @sh))"),
  "config_loaded=1"
JQ

names=()
declare -A c_exec=() c_fast=() c_enable=() c_requires=() c_coverage=()
# The percentage of the new lines a coverage report can cover that must be covered.
new_code=
loose_check=()
loose_kind=()
loose_reason=()
# A new-code loosening's threshold and assay's default, "<newCode> <default>"; a setting's, what it is; empty for the
# others.
loose_value=()
# The languages the repo enables, and the rule packs it turns on with their directories, in name order.
cfg_languages=()
pack_names=()
pack_dirs=()
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

# Every check, in name order, the fast ones and the off ones marked: "<name>", "<name> (fast)", "<name> (off)" or
# "<name> (fast, off)".
list_checks() {
	local n marks
	for n in "${names[@]}"; do
		marks=
		if [ "${c_fast[$n]}" = 1 ]; then marks=fast; fi
		if [ "${c_enable[$n]}" != 1 ]; then marks+="${marks:+, }off"; fi
		echo "$n${marks:+ ($marks)}"
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
	local index untracked objects store index_path
	tmp_file index
	tmp_file untracked
	# Intent-to-add writes the empty blob: objects git writes go to a throwaway store, the repo's own an alternate.
	tmp_file objects -d
	store=$(git rev-parse --path-format=absolute --git-path objects) || die "cannot find the object store"
	index_path=$(git rev-parse --git-path index) || die "cannot find the index"
	cp -- "$index_path" "$index" 2>/dev/null || rm -f -- "$index"
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
IFS= read -r -d '' diff_awk <<'AWK' || true
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
AWK

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
IFS= read -r -d '' new_code_jq <<'JQ' || true
split("\u0000") | .[:-1] as $f
| reduce range(0; $f | length; 3) as $i ({}; .[$f[$i]] += [[($f[$i + 1] | tonumber), ($f[$i + 2] | tonumber)]])
JQ
new_code_json() {
	new_code "$1" | jq -S -R -s "$new_code_jq"
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
	if [ "$a_type" = symlink ]; then case $a_content in CLAUDE.md | ./CLAUDE.md) a_to_c=1 ;; esac fi
	if [ "$c_type" = symlink ]; then case $c_content in AGENTS.md | ./AGENTS.md) c_to_a=1 ;; esac fi

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
	local re='^[[:space:]]*co-authored-by[[:space:]]*:' list commit subject line base_short message
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
		message=$(git log -1 --no-show-signature --format=%B "$commit") || die "cannot read the commit $commit"
		while IFS= read -r line; do
			if [[ ${line,,} =~ $re ]]; then echo "      ${line#"${line%%[![:space:]]*}"}"; fi
		done <<<"$message"
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
	local diff removed ranges records path first last n=0 rc=0
	local -a files=()
	local -A position=()
	parse_base_option suppressions "$@"
	find_repo
	resolve_base
	tmp_file diff
	tmp_file removed
	tmp_file ranges
	tmp_file records
	change_diff "$base_sha" >"$diff"
	new_code "$diff" "$removed" >"$records" || die "cannot read the change's new code"
	while IFS= read -r -d '' path && IFS= read -r -d '' first && IFS= read -r -d '' last; do
		if [ -z "${position[$path]+set}" ]; then
			if [ -L "$path" ] || [ ! -f "$path" ]; then continue; fi
			n=$((n + 1))
			position[$path]=$n
			files+=("./$path")
		fi
		printf '%s\t%s\t%s\n' "${position[$path]}" "$first" "$last"
	done <"$records" >"$ranges"
	[ "$n" -gt 0 ] || finish 0
	LC_ALL=C awk "$suppressions_awk" "$removed" "$ranges" "${files[@]}" || rc=$?
	case $rc in
	0 | 1) finish "$rc" ;;
	*) die "cannot read the files that hold new code (awk exit $rc)" ;;
	esac
}

# Presets: the configuration files a language's default checks need in a repo. assay holds every version of each
# language's preset, under preset/<language>/<version>/ (the files at the paths they take in the repo); its highest
# version is the one the repo pins. `assay preset` writes it into the repo, which owns the files from then on, and
# records the version it took in .assay-preset.json at the root: {"<language>": <version>}.
record_file=.assay-preset.json

# find_presets: sets presets to the directory that holds assay's presets. The package sets assay_presets on the line
# before this script; run from a checkout, it is preset/ beside the script.
presets=
find_presets() {
	local self
	if [ -n "${assay_presets:-}" ]; then
		presets=$assay_presets
	else
		self=$(realpath -- "${BASH_SOURCE[0]}") || die "cannot find where assay's script is"
		presets=${self%/*}/preset
	fi
	[ -d "$presets" ] || die "cannot find assay's presets at $presets"
}

# preset_pinned <language>: sets pinned to the highest version of the language's preset, 0 when assay has none.
pinned=0
preset_pinned() {
	local d v
	pinned=0
	[[ $1 =~ $name_re ]] || return 0
	for d in "$presets/$1"/*/; do
		v=${d%/}
		v=${v##*/}
		if [[ $v =~ ^[1-9][0-9]{0,8}$ ]] && [ "$v" -gt "$pinned" ]; then pinned=$v; fi
	done
}

# preset_applies <language>: whether the language's preset applies to the repo (the current directory, its root),
# with applies_why set to what makes it apply. bash's applies once the repo tracks a shell script.
applies_why=
preset_applies() {
	case $1 in
	bash) has_shell_script ;;
	scala)
		applies_why="the repo has build.sbt"
		[ -f build.sbt ]
		;;
	*) return 1 ;;
	esac
}

# has_shell_script: the repo tracks a shell script that is in the working tree, as shfmt -f finds them (by extension
# or shebang, .bats files included), the way bash's checks find the files they run on. Without shfmt it exits
# missing_tool_exit: 2, or 127 for `assay builtin preset`, as for any built-in check whose tool is missing.
missing_tool_exit=2
has_shell_script() {
	local list found f i
	local -a files=()
	tmp_file list
	tmp_file found
	git ls-files -z --cached --deduplicate >"$list" || die "cannot list the files git tracks"
	while IFS= read -r -d '' f; do
		if [ -f "$f" ]; then files+=("./$f"); fi
	done <"$list"
	[ ${#files[@]} -gt 0 ] || return 1
	if ! command -v shfmt >/dev/null; then
		echo "assay: cannot find shfmt on the PATH, which tells shell scripts apart" >&2
		finish "$missing_tool_exit"
	fi
	for ((i = 0; i < ${#files[@]}; i += 1000)); do
		shfmt -f "${files[@]:i:1000}" >"$found" || die "shfmt -f failed on the tracked files"
		if IFS= read -r f <"$found"; then
			applies_why="the repo tracks the shell script ${f#./}"
			return 0
		fi
	done
	return 1
}

# absent <path>: nothing is at the path, not even a dangling symlink.
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# has_markers <file> <language>: the file holds the closing marker of a conflict with the language's preset, which
# apply_preset leaves for a person to resolve.
has_markers() {
	awk -v closing=">>>>>>> $2's preset " 'index($0, closing) == 1 { found = 1; exit } END { exit !found }' "$1"
}

# load_record: the record at the repo root (the current directory) into recorded, <language> => <version>; empty
# when the repo has none. Returns 1, with record_error set, when it is not one JSON object whose values are positive
# integers.
declare -A recorded=()
record_error=
# shellcheck disable=SC2016 # jq's $variables, not the shell's
record_jq='
def fail($m): "\($m)\n" | halt_error(1);
[inputs]
| if length != 1 then fail("expected one JSON document, found \(length)") else .[0] end
| if type != "object" then fail("not a JSON object") else . end
| to_entries[]
| if (.key | test($name_re) | not) then fail("bad language name \(.key | tojson)")
  elif (.value | type) != "number" or .value != (.value | floor) or .value < 1 or .value > 999999999 then
    fail("\(.key): the version must be a positive integer, not \(.value | tojson)")
  else "recorded[\(.key | @sh)]=\(.value | floor)" end
'
load_record() {
	local out
	recorded=()
	if absent "$record_file"; then return 0; fi
	if ! out=$(jq -n -r --arg name_re "$name_re" "$record_jq" "$record_file" 2>&1); then
		record_error=$out
		return 1
	fi
	eval "$out"
}
# read_record: load_record, dying when the record cannot be read.
read_record() {
	load_record || die "cannot read $record_file: $record_error"
}

# presets_behind: the header line of `assay check` for each language whose recorded preset version is behind the
# pinned one. A version behind fails nothing. A record that cannot be read adds no line: the preset check fails on it.
presets_behind() {
	local d lang
	load_record || return 0
	if [ ${#recorded[@]} -eq 0 ]; then return 0; fi
	find_presets
	for d in "$presets"/*/; do
		lang=${d%/}
		lang=${lang##*/}
		[ -n "${recorded[$lang]+set}" ] || continue
		preset_pinned "$lang"
		if [ "${recorded[$lang]}" -lt "$pinned" ]; then
			echo "  preset behind: $lang ${recorded[$lang]} → $pinned (assay preset $lang)"
		fi
	done
}

# preset: every enabled language whose preset applies is in the record. Its last line is the command that fixes it.
builtin_preset() {
	local lang
	local -a missing=()
	[ $# -eq 0 ] || usage_error "preset takes no argument"
	missing_tool_exit=127
	load_config
	find_repo
	find_presets
	read_record
	for lang in "${cfg_languages[@]}"; do
		preset_pinned "$lang"
		if [ "$pinned" -eq 0 ] || [ -n "${recorded[$lang]+set}" ]; then continue; fi
		if preset_applies "$lang"; then
			missing+=("$lang")
			echo "$lang's preset applies ($applies_why), and $record_file does not list $lang"
		fi
	done
	[ ${#missing[@]} -gt 0 ] || finish 0
	echo "run: assay preset ${missing[*]}"
	finish 1
}

# preset_others <language> <file>: sets others to the other files the tool of a preset file reads in its place, in
# the tool's order. When the repo has one and not the preset's file, that one is the tool's: the preset writes no file
# of its own beside it, which would silently replace it, and merges into it and shows it as it would its own file
# (each has the preset file's format). shellcheck reads shellcheckrc where a directory has no .shellcheckrc.
others=()
preset_others() {
	others=()
	case $1/$2 in
	bash/.shellcheckrc) others=(shellcheckrc) ;;
	esac
}

# preset_files <dir>: the files under a version's directory, relative to it, NUL-terminated, in byte order.
preset_files() (
	LC_ALL=C
	shopt -s globstar dotglob nullglob
	cd -- "$1" || exit 1
	for f in **; do
		if [ -f "$f" ]; then printf '%s\0' "$f"; fi
	done
)

# same_content <file> <file>: the two files hold the same text.
same_content() {
	local a b
	a=$(cat -- "$1" && echo .) || die "cannot read $1"
	b=$(cat -- "$2" && echo .) || die "cannot read $2"
	[ "$a" = "$b" ]
}

# What `assay preset` did, filled by apply_preset: a line per file it wrote, merged or kept; the diffs of the kept
# files that differ from the preset; the last lines, saying what is left to do; whether a version it recorded changed.
preset_lines=()
preset_shown=
preset_todo=()
record_changed=0

render_scalafmt() {
	local version
	version=$(scalafmt --version) || die "cannot read scalafmt's version"
	[[ $version =~ ^scalafmt\ ([0-9]+(\.[0-9]+)+)$ ]] || die "unexpected scalafmt version: $version"
	sed "s/@SCALAFMT_VERSION@/${BASH_REMATCH[1]}/g" "$1" >"$2" || die "cannot render $1"
}

# apply_preset <language>: the language's pinned preset into the repo (the current directory, its root), file by
# file, and its version into recorded. A file the repo lacks is written. With no version recorded (an adoption), a file
# the repo has is kept, and shown against the preset when they differ. With an older version recorded, the repo's file
# is merged three ways (git merge-file): the base is the recorded version's file, theirs the pinned one's, ours the
# repo's; a conflict leaves its markers in the file, and every later run reports them until they are resolved. The
# version is recorded whatever the outcome, so that a conflict once resolved, or a kept file once extended, is not
# merged again.
apply_preset() {
	local lang=$1 from=${recorded[$1]:-} to f target other theirs base merged files diff rc todo changed=0
	preset_pinned "$lang"
	to=$pinned
	if [ -n "$from" ] && [ "$from" -gt "$to" ]; then
		die "$record_file records $lang's preset $from, newer than this assay's $to: update assay (devenv update assay)"
	fi
	if [ -n "$from" ] && [ ! -d "$presets/$lang/$from" ]; then
		die "$record_file records $lang's preset $from, which this assay does not hold"
	fi
	tmp_file files
	tmp_file merged
	tmp_file diff
	tmp_file base
	preset_files "$presets/$lang/$to" >"$files" || die "cannot list $presets/$lang/$to"
	while IFS= read -r -d '' f; do
		theirs=$presets/$lang/$to/$f
		if [[ $lang/$f == scala/.scalafmt.conf ]]; then
			tmp_file theirs
			render_scalafmt "$presets/$lang/$to/$f" "$theirs"
		fi
		target=$f
		if absent "$f"; then
			preset_others "$lang" "$f"
			for other in "${others[@]}"; do
				if ! absent "$other"; then
					target=$other
					break
				fi
			done
		fi
		if absent "$target"; then
			if [[ $target == */* ]]; then mkdir -p -- "${target%/*}" || die "cannot create ${target%/*}"; fi
			cat -- "$theirs" >"$target" || die "cannot write $target"
			preset_lines+=("wrote $target")
			changed=1
			continue
		fi
		[ -f "$target" ] || die "$target is not a file, and $lang's preset has one there"
		if [ -z "$from" ]; then
			preset_lines+=("kept $target")
			changed=1
			if same_content "$target" "$theirs"; then continue; fi
			rc=0
			git -c core.quotePath=false diff --no-index --no-color --no-ext-diff --no-textconv -U3 -- "$target" "$theirs" \
				>"$diff" || rc=$?
			[ "$rc" -eq 1 ] || die "cannot compare $target with $lang's preset (git diff exit $rc)"
			preset_shown+=$'\n'"--- $target, kept, against $lang's preset $to (the + lines are the preset's)"$'\n'
			preset_shown+=$(awk '/^@@/ { on = 1 } on' "$diff") || die "cannot read the comparison of $target"
			preset_shown+=$'\n'
			todo="$target differs from $lang's preset $to: extend it by hand to hold what the preset holds (the + lines"
			preset_todo+=("$todo above), keeping what the repo needs of its own")
			continue
		fi
		if [ "$from" = "$to" ]; then
			if has_markers "$target" "$lang"; then
				preset_lines+=("conflict $target")
				changed=1
				preset_todo+=("$target holds the markers of a conflict with $lang's preset: resolve them")
			fi
			continue
		fi
		if [ -f "$presets/$lang/$from/$f" ]; then
			if [[ $lang/$f == scala/.scalafmt.conf ]]; then
				render_scalafmt "$presets/$lang/$from/$f" "$base"
			else
				cat -- "$presets/$lang/$from/$f" >"$base" || die "cannot read $lang's preset $from"
			fi
		else
			: >"$base"
		fi
		# The preset did not change the file between the two versions.
		if same_content "$base" "$theirs"; then continue; fi
		rc=0
		git merge-file -p --diff3 -L "$target" -L "$lang's preset $from" -L "$lang's preset $to" \
			"$target" "$base" "$theirs" >"$merged" || rc=$?
		if [ "$rc" -eq 0 ] && same_content "$merged" "$target"; then continue; fi
		if [ "$rc" -ge 128 ]; then die "git merge-file failed on $target (exit $rc)"; fi
		cat -- "$merged" >"$target" || die "cannot write $target"
		changed=1
		if [ "$rc" -eq 0 ]; then
			preset_lines+=("merged $target")
		else
			preset_lines+=("conflict $target")
			todo="$target conflicts with $lang's preset $to: resolve its markers (<<<<<<< the repo's lines, ||||||| $lang's"
			preset_todo+=("$todo preset $from, >>>>>>> $lang's preset $to)")
		fi
	done <"$files"
	if [ "$from" != "$to" ]; then
		recorded[$lang]=$to
		record_changed=1
	elif [ "$changed" = 0 ]; then
		preset_lines+=("$lang's preset $to: up to date")
	fi
}

# write_record: recorded into the record, its keys sorted, as jq prints it (which is how oxfmt formats JSON).
write_record() {
	local lang json
	json=$(for lang in "${!recorded[@]}"; do printf '%s\t%s\n' "$lang" "${recorded[$lang]}"; done |
		jq -n -R -S '[inputs | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries') ||
		die "cannot build $record_file"
	printf '%s\n' "$json" >"$record_file" || die "cannot write $record_file"
}

# assay preset [<language>...]: the pinned preset of each language named, or of every enabled language whose preset
# applies, into the repo (apply_preset), then the versions taken into the record. Exits 0 when everything applied, 1
# on a conflict or a kept file that differs from the preset.
cmd_preset() {
	local arg lang d
	local -a langs=() known=()
	local -A seen=()
	for arg; do
		case $arg in
		-h | --help)
			usage_text
			finish 0
			;;
		-*) usage_error "unknown option '$arg'" ;;
		*) ;;
		esac
	done
	load_config
	find_repo
	find_presets
	read_record
	for d in "$presets"/*/; do
		d=${d%/}
		d=${d##*/}
		preset_pinned "$d"
		if [ "$pinned" -gt 0 ]; then known+=("$d"); fi
	done
	if [ $# -gt 0 ]; then
		for lang; do
			preset_pinned "$lang"
			[ "$pinned" -gt 0 ] || usage_error "assay has no preset for '$lang'; it has one for: ${known[*]}"
			if [ -z "${seen[$lang]:-}" ]; then langs+=("$lang"); fi
			seen[$lang]=1
		done
	else
		for lang in "${cfg_languages[@]}"; do
			preset_pinned "$lang"
			if [ "$pinned" -eq 0 ] || [ -n "${seen[$lang]:-}" ]; then continue; fi
			seen[$lang]=1
			if preset_applies "$lang"; then langs+=("$lang"); fi
		done
	fi
	if [ ${#langs[@]} -eq 0 ]; then
		echo "no preset to apply: no language this repo's devenv enables has a preset that applies"
		finish 0
	fi
	for lang in "${langs[@]}"; do apply_preset "$lang"; done
	if [ "$record_changed" = 1 ]; then
		write_record
		preset_lines+=("wrote $record_file")
	fi
	printf '%s\n' "${preset_lines[@]}"
	[ ${#preset_todo[@]} -gt 0 ] || finish 0
	printf '%s' "$preset_shown"
	echo
	printf '%s\n' "${preset_todo[@]}"
	finish 1
}

# The analyzer. `assay findings` runs qlty in the repo itself, with no server: `qlty check`, whose findings qlty keeps to
# the changed lines, and `qlty smells`, which reports every smell of a changed file. qlty runs only what no other
# check runs: radarlint's plugins, for Python and Scala, and smells, for TypeScript, Rust, Python and Scala. The
# built-in `findings` check fails on the new findings among those `assay findings` shows.

# .qlty/qlty.toml, from the configuration's `findings` settings (qlty's own defaults for what it leaves out), with
# radarlint's plugins pointed at $radarlint, an absolute path: qlty runs plugins with an empty PATH, and would
# download its own tools for its own plugin definitions. The rules end the plugin's script as a shell comment: qlty
# keys its cache of radarlint's results by the script, not by radarlint.properties.
IFS= read -r -d '' findings_toml_jq <<'JQ' || true
(.findings // {}) as $f
| (($f.rules // {}) | to_entries | map("\(.key)=\(.value)") | join(" ")) as $rules
| "# Written by assay on every run, from assay.findings: an edit here does not last.",
  "config_version = \"0\"",
  (($f.smells // {}) | to_entries[] | "", "[smells.\(.key)]", "enabled = \(.value.enable)", "threshold = \(.value.threshold)"),
  # One value per repo, not per language: Rust has its own in qlty's defaults.
  (if $f.duplication then "", "[smells.duplication]", "nodes_threshold = \($f.duplication.nodes_threshold)",
     "", "[language.rust]", "smells.duplication.nodes_threshold = \($f.duplication.nodes_threshold)" else empty end),
  (($f.radarlint // [])[] as $language | "radarlint-\($language)" as $plugin
    | "", "[plugins.definitions.\($plugin)]", "file_types = [\($language | tojson)]",
      "config_files = [\"radarlint.properties\"]", "latest_version = \"assay\"", "known_good_version = \"assay\"",
      "", "[plugins.definitions.\($plugin).drivers.lint]",
      "script = \("\($radarlint | @sh) \($language) ${target} # rules: \($rules)" | tojson)",
      "success_codes = [0, 1]", "output = \"stdout\"",
      "output_format = \"sarif\"", "output_missing = \"error\"", "batch = true", "cache_results = true"),
  (($f.radarlint // [])[] | "", "[[plugin]]", "name = \("radarlint-\(.)" | tojson)", "version = \"assay\"")
JQ

# .qlty/configs/radarlint.properties, which radarlint reads from the directory it runs in: qlty links it into the repo
# root while radarlint runs. A rule python:S3776 is radarlint.rules.python.S3776.
radarlint_properties_jq='(.findings.rules // {}) | to_entries[] | "radarlint.rules.\(.key | sub(":"; "."))=\(.value)"'

# What both programs over qlty's SARIF need. A path is a URI there, percent-encoded, non-ASCII characters included.
IFS= read -r -d '' sarif_defs <<'JQ' || true
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
# A linter's finding is about a place in the code; a smell, about a piece of it: a function, a file, a block, an
# expression or a clone.
def about_a_place($run): $run == "lint";
def clone: .ruleId | IN("qlty:identical-code", "qlty:similar-code");
JQ

# The findings on the change as one SARIF log, {"runs": [lint, smells]}, each result marked new or not with SARIF's
# baselineState. A linter'"'"'s finding is new when any of its lines is new code, as qlty keeps them to changed lines. A
# smell is new when the base has no counterpart: the same rule, file (through renames) and function; for a clone'"'"'s
# place, a clone'"'"'s place in the same file, between the same files. So a smell the base has, grown or edited, is not
# new. A nested block or an expression has no function to tell it from another of the file: it is also new when it
# starts on new code. qlty'"'"'s hash of a clone is no identity: a clone grows or
# shrinks to the largest piece of code its places share, so an unrelated edit next to one changes it. With more of one
# counterpart now than at the base, the ones that do not start on new code take the base'"'"'s first.
IFS= read -r -d '' findings_jq <<'JQ' || true
($config[0].findings.rules // {}) as $rules
| $new_code[0] as $new_code | $renames[0] as $renames
| def in_smell_languages: (place.region.sourceLanguage // "") | IN("python", "rust", "scala", "tsx", "typescript");
  def rule_on: ($rules[.ruleId // "" | sub("^[^:]*:"; "")]) != false;
  def new_code($from; $to): path as $p | any($new_code[$p][]?; .[0] <= $to and $from <= .[1]);
  def on_new_code($run): if about_a_place($run) then new_code(line; last_line) else new_code(line; line) end;
  def without_function: .ruleId | IN("qlty:nested-control-flow", "qlty:boolean-logic");
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
| ($entries
    | map(.result + {baselineState:
        (if .on_new_code and (.result | without_function) then "new" else $states[.i | tostring] end)}))
    as $smells_results
| {"$schema": "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json",
   version: "2.1.0",
   runs: [($lint[0].runs[0] + {results: $lint_results}), ($smells[0].runs[0] + {results: $smells_results})]}
JQ

# The text of a findings log: by file, a blank line between files; in a file the lint findings, then the smells, by
# line, as "<path>:<line>: <tool>/<rule>: <message>", a clone followed by its places. With $only_new, the new ones
# only, and nothing at all without any.
IFS= read -r -d '' findings_text_jq <<'JQ' || true
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
JQ

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
	local exclude last
	if git ls-files --error-unmatch -- .qlty/qlty.toml >/dev/null 2>&1; then
		die "the repo tracks .qlty/qlty.toml, which assay writes on every run from assay.findings: move its settings" \
			"there and remove the file from git"
	fi
	exclude=$(git rev-parse --path-format=absolute --git-path info/exclude) || die "cannot find .git/info/exclude"
	if ! grep -qxF .qlty/ "$exclude" 2>/dev/null; then
		# Empty when the file is missing, empty, or ends in a newline.
		last=
		if [ -s "$exclude" ]; then last=$(tail -c 1 "$exclude") || last=; fi
		{
			mkdir -p "$(dirname "$exclude")" &&
				if [ -n "$last" ]; then echo >>"$exclude"; fi &&
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
	jq -j --slurpfile renames "$renames" \
		"$sarif_defs"'[.runs[]?.results[]? | path] | unique[] | ($renames[0][.] // .) + "\u0000"' "$smells" >"$paths" ||
		die "cannot read qlty's smells"
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

# The marker that opens each placeholder `assay rule new` writes: "<fill in: what goes here>".
rule_placeholder='<fill in:'

# sg_load: the root's sgconfig.yml as compact JSON, in sg_json. Returns 1, with yq's error on one line in sg_error, when
# it cannot be read as YAML.
sg_json=
sg_error=
sg_load() {
	command -v yq >/dev/null || die "cannot find yq on the PATH"
	if ! sg_json=$(yq -o=json -I=0 '.' sgconfig.yml 2>&1); then
		sg_error=${sg_json//$'\n'/ }
		return 1
	fi
}

# sg_dirs <rules|tests|all>: the directories sgconfig.yml names (sg_load first), NUL-terminated, in its order: its
# ruleDirs, its testConfigs' testDir, or every one of those and its utilDirs.
sg_dirs() {
	# shellcheck disable=SC2016 # jq's program, not the shell's
	jq -j -n --arg kind "$1" 'def names: if type == "array" then .[] | select(type == "string" and length > 0) else empty end;
		input | (if $kind == "tests" then empty else (try .ruleDirs catch null) | names end),
			(if $kind == "all" then (try .utilDirs catch null) | names else empty end),
			(if $kind == "rules" then empty else [(try .testConfigs[] catch empty) | try .testDir catch null] | names end)
		| . + "\u0000"' <<<"$sg_json" || die "cannot read the directories sgconfig.yml names"
}

# root_relative <path>: the path relative to the repo root (the current directory) when it lies inside the repo, else
# absolute.
root_relative() {
	local abs
	abs=$(realpath -m -s -- "$1") || die "cannot resolve $1"
	case $abs in
	"$root") echo . ;;
	"$root"/*) echo "${abs#"$root"/}" ;;
	*) echo "$abs" ;;
	esac
}

# sg_grep <out> <pattern> <pathspec>...: the lines that hold the fixed string, in the files git sees (tracked, or
# untracked but not ignored; binary files left out), as <path>:<line>:<text>, into <out>. Every option that a user's
# configuration could change is fixed. Returns 1 when no line does.
sg_grep() {
	local out=$1 pattern=$2 rc=0
	shift 2
	git -c core.quotePath=false grep --untracked -I -n -F --full-name --no-color --no-column --no-recurse-submodules \
		--no-textconv -e "$pattern" -- "$@" >"$out" || rc=$?
	case $rc in
	0 | 1) return "$rc" ;;
	*) die "cannot search the working tree for $pattern" ;;
	esac
}

# sg_run <ast-grep argument>...: print the command, then run it with its output on stdout; returns its exit code.
sg_run() {
	local arg shown="\$ ast-grep" rc=0
	for arg in "$@"; do shown+=" $(shell_word "$arg")"; done
	echo "$shown"
	ast-grep "$@" 2>&1 || rc=$?
	return "$rc"
}

# ast-grep: the repo's ast-grep rules (sgconfig.yml at the root, whatever directories it names) and the rule packs the
# configuration turns on (rulePacks, each an ast-grep project of its own, scanning the repo from its root), in three
# steps, in order:
# 1. a plain text search of the files git sees, for ast-grep-ignore outside the rule directories (a bare one on a line
#    also silences a rule written to forbid it, so exceptions live in the rule's own file), and for the placeholders
#    of `assay rule new` inside them;
# 2. `ast-grep test --skip-snapshot-tests` (snapshots only restate the message, and ast-grep test fails without them);
# 3. `ast-grep scan`, which exits 1 on an error finding.
# Every step runs, so that one run shows every failure, but a placeholder ends the check after the first: the rule is
# not written yet, and ast-grep would take its placeholder pattern for code. ast-grep's own errors (a rule it cannot
# read, a missing rule directory) fail the step they happen in.
builtin_ast_grep() {
	local has_config=0 hits dirs count d i config ignores=0 placeholders=0 tests_failed=0 scan_failed=0 all_inside=0
	local -a excluded=() inside=()
	[ $# -eq 0 ] || usage_error "ast-grep takes no argument"
	load_config
	find_repo
	if [ -f sgconfig.yml ]; then has_config=1; fi
	if [ "$has_config" = 0 ] && [ ${#pack_names[@]} -eq 0 ]; then finish 0; fi
	if ! command -v ast-grep >/dev/null; then
		echo "assay: cannot find ast-grep on the PATH" >&2
		finish 127
	fi

	# 1. The plain text search, outside and inside the rule directories that lie in the repo.
	tmp_file hits
	if [ "$has_config" = 1 ]; then
		if ! sg_load; then
			echo "sgconfig.yml cannot be read as YAML: $sg_error"
			finish 1
		fi
		tmp_file dirs
		sg_dirs all >"$dirs"
		while IFS= read -r -d '' d; do
			d=$(root_relative "$d")
			case $d in
			/*) continue ;;
			.) all_inside=1 ;;
			esac
			excluded+=(":(top,exclude,literal)$d")
			inside+=(":(top,literal)$d")
		done <"$dirs"
	fi
	if [ "$all_inside" = 0 ] && sg_grep "$hits" ast-grep-ignore . "${excluded[@]}"; then
		cat "$hits"
		count=$(wc -l <"$hits")
		if [ "$count" -eq 1 ]; then echo -n "1 line with"; else echo -n "$count lines with"; fi
		echo " ast-grep-ignore outside the rule directories: remove each one. An exception lives in the rule's own file" \
			"(its ignores, or a not: clause in its rule), where a review sees it; an ast-grep-ignore also silences a rule" \
			"written to forbid it."
		ignores=1
	fi
	if [ ${#inside[@]} -gt 0 ] && sg_grep "$hits" "$rule_placeholder" "${inside[@]}"; then
		cat "$hits"
		count=$(wc -l <"$hits")
		if [ "$count" -eq 1 ]; then echo -n "1 placeholder"; else echo -n "$count placeholders"; fi
		echo " of assay rule new left in the rules and their tests: fill each one in, as the comment above its field says."
		placeholders=1
	fi
	[ "$placeholders" = 0 ] || finish 1

	# 2. The rules' tests: the repo's, then each pack's.
	if [ "$has_config" = 1 ]; then sg_run test --skip-snapshot-tests --color never || tests_failed=1; fi
	for i in "${!pack_names[@]}"; do
		sg_run test -c "${pack_dirs[$i]}/sgconfig.yml" --skip-snapshot-tests --color never || tests_failed=1
	done
	if [ "$tests_failed" = 1 ]; then
		echo "ast-grep test failed: each rule reports its invalid cases and none of its valid ones; fix the rule or its tests."
	fi

	# 3. The scan: the repo's rules, then each pack's.
	if [ "$has_config" = 1 ] && ! sg_run scan --color never; then
		echo "ast-grep scan found code a rule forbids: fix each finding; \`ast-grep scan -U\` applies a rule's fix:," \
			"where it has one."
		scan_failed=1
	fi
	for i in "${!pack_names[@]}"; do
		if ! sg_run scan -c "${pack_dirs[$i]}/sgconfig.yml" --color never; then
			config=$(shell_word "${pack_dirs[$i]}/sgconfig.yml")
			echo "ast-grep scan found code a rule forbids: fix each finding;" \
				"\`ast-grep scan -c $config -U\` applies a pack rule's fix:, where it has one."
			scan_failed=1
		fi
	done
	if [ "$ignores$tests_failed$scan_failed" = 000 ]; then finish 0; fi
	finish 1
}

# tla: TLC over the repo's TLA+ models: each configuration tla/<Name>.cfg that git sees (tracked, or untracked but not
# ignored) against tla/<Name>.tla, one after another in name order, every one run so that one run shows every failure.
# One worker and a pinned fingerprint polynomial keep the result and a violation's trace the same from run to run.
# Nothing is written into the tree: TLC's states go to <git-dir>/assay/tla (-metadir), emptied first, where TLC leaves
# them after a violation; Java's temporary files, where TLC unpacks its standard modules, to its tmp/; and
# -noGenerateSpecTE keeps TLC from writing a trace module beside the spec. Any non-zero exit of TLC fails the check
# (12 an invariant violated, 11 a deadlock, 150 and 151 parse and configuration errors), its trace in the output.
builtin_tla() {
	# fp: which of TLC's fingerprint polynomials (-fp) every run uses.
	local dir list cfg spec rc fp=0
	local -a cfgs=() failures=()
	[ $# -eq 0 ] || usage_error "tla takes no argument"
	find_repo
	if ! command -v tlc >/dev/null; then
		echo "assay: cannot find tlc on the PATH" >&2
		finish 127
	fi
	dir=$gitdir/assay/tla
	rm -rf "${dir:?}"
	mkdir -p "$dir/tmp" || die "cannot create $dir"
	tmp_file list
	git ls-files -z --cached --others --exclude-standard --deduplicate -- ':(top,glob)tla/*.cfg' >"$list" ||
		die "cannot list the working tree"
	LC_ALL=C sort -z -o "$list" "$list" || die "cannot sort $list"
	while IFS= read -r -d '' cfg; do
		if [ -f "$cfg" ]; then cfgs+=("$cfg"); fi
	done <"$list"
	if [ ${#cfgs[@]} -eq 0 ]; then
		echo "no tla/*.cfg to check"
		finish 0
	fi
	for cfg in "${cfgs[@]}"; do
		spec=${cfg%.cfg}.tla
		if [ ! -f "$spec" ]; then
			failures+=("$cfg: no $spec beside it")
			continue
		fi
		echo "\$ tlc -workers 1 -fp $fp -noGenerateSpecTE -metadir $dir -config $cfg $spec"
		rc=0
		JDK_JAVA_OPTIONS="${JDK_JAVA_OPTIONS:+$JDK_JAVA_OPTIONS }-Djava.io.tmpdir=$dir/tmp" \
			tlc -workers 1 -fp "$fp" -noGenerateSpecTE -metadir "$dir" -config "$cfg" "$spec" </dev/null 2>&1 ||
			rc=$?
		echo
		if [ "$rc" -ne 0 ]; then failures+=("$cfg: TLC exit $rc"); fi
	done
	[ ${#failures[@]} -gt 0 ] || finish 0
	printf '%s\n' "${failures[@]}"
	if [ ${#cfgs[@]} -eq 1 ]; then
		echo "1 of 1 TLA+ configuration failed"
	else
		echo "${#failures[@]} of ${#cfgs[@]} TLA+ configurations failed"
	fi
	finish 1
}

cmd_builtin() {
	[ $# -ge 1 ] || usage_error "builtin needs the name of a built-in check"
	local check=$1
	shift
	case $check in
	agents-md) builtin_agents_md "$@" ;;
	ast-grep) builtin_ast_grep "$@" ;;
	commit-trailers) builtin_commit_trailers "$@" ;;
	gitleaks) builtin_gitleaks "$@" ;;
	preset) builtin_preset "$@" ;;
	suppressions) builtin_suppressions "$@" ;;
	findings) builtin_findings "$@" ;;
	tla) builtin_tla "$@" ;;
	*) usage_error "no built-in check named '$check'" ;;
	esac
}

# assay rule new: the scaffold of an ast-grep rule, in ast-grep's own layout, whose placeholders fail the ast-grep
# check until they are filled in. Only ast-grep rules: a native rule is a line in its tool's configuration, and a
# guard rule a Nix entry.

# A shell script's shebang: sh, bash, dash, ksh or bats, by path or through env.
shebang_re='^#![[:space:]]*[^[:space:]]*/(env[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?((ba|da|k)?sh|bats)([[:space:]]|$)'

# lang_of_file <path>: the ast-grep language of a file, in lowercase: bash for a script whose name has no extension and
# whose shebang names a shell, else the one ast-grep parses it as (by its extension, or the languageGlobs of the
# sgconfig.yml it finds); nothing when it has none.
lang_of_file() {
	local first="" out
	if [[ ${1##*/} != ?*.* ]]; then
		IFS= read -r first <"$1" || true
		if [[ $first =~ $shebang_re ]]; then
			echo bash
			return 0
		fi
	fi
	# Any node matches $A, and the first match names the language; the file holds at least one non-blank line.
	# shellcheck disable=SC2016 # ast-grep's metavariable $A, not the shell's
	out=$(ast-grep run -p '$A' --json=stream -- "$1" 2>/dev/null | head -n 1) || true
	jq -r '.language // empty | ascii_downcase' <<<"$out" 2>/dev/null || true
}

# from_case <file> <first> <last>: lines <first> to <last> of the file as the first item of a YAML list, indented by
# two: dedented by the whitespace they all start with, trailing whitespace cut, as a block scalar; or as a quoted
# string when the first line still starts with whitespace (a block scalar would take it for indentation) or a line
# holds a control character other than a tab. Dies when the file is shorter, or the lines are blank.
from_case() {
	local file=$1 first=$2 last=$3 text line range quoted
	# shellcheck disable=SC2016 # awk's $0, not the shell's
	text=$(LC_ALL=C awk -v first="$first" -v last="$last" '
    NR >= first && NR <= last { sub(/[ \t]+$/, ""); line[++n] = $0 }
    END {
      if (NR < last) { print NR; exit 3 }
      for (i = 1; i <= n; i++) if (line[i] != "") { match(line[i], /^[ \t]*/); ws = substr(line[i], 1, RLENGTH)
        if (!have++) prefix = ws; else { j = 0; while (j < length(prefix) && substr(prefix, j + 1, 1) == substr(ws, j + 1, 1)) j++; prefix = substr(prefix, 1, j) } }
      if (!have) exit 4
      for (i = 1; i <= n; i++) print (line[i] == "") ? "" : substr(line[i], length(prefix) + 1)
    }' "$file") || {
		case $? in
		3) die "--from: $file has $text lines, not $last" ;;
		4)
			if [ "$first" = "$last" ]; then range="line $first of $file is"; else range="lines $first-$last of $file are"; fi
			die "--from: $range blank"
			;;
		*) die "--from: cannot read $file" ;;
		esac
	}
	if [[ $text =~ ^[[:space:]] ]] || LC_ALL=C grep -q '[[:cntrl:]]' <<<"${text//$'\t'/ }"; then
		quoted=$(jq -Rs . <<<"$text") || die "--from: cannot quote the lines of $file"
		printf '  - %s\n' "$quoted"
	else
		printf '  - |\n'
		while IFS= read -r line; do
			if [ -z "$line" ]; then echo; else printf '    %s\n' "$line"; fi
		done <<<"$text"
	fi
}

# first_dir <rules|tests>: the first directory of that kind sgconfig.yml names (sg_load first), relative to the root
# when it lies inside the repo; nothing when it names none.
first_dir() {
	local list d
	tmp_file list
	sg_dirs "$1" >"$list"
	if IFS= read -r -d '' d <"$list"; then root_relative "$d"; fi
}

# rule_new <argument>...: `assay rule new`. Writes the scaffold and prints the paths it created, relative to the
# directory it was called from.
rule_new() {
	local name="" lang="" lang_set=0 from="" from_set=0 file="" first="" last="" case_file rule_dir test_dir d f hit list
	local caller_dir dirs
	local -a created=()
	caller_dir=$(pwd -P) || die "cannot read the current directory"
	while [ $# -gt 0 ]; do
		case $1 in
		--lang)
			[ $# -ge 2 ] || usage_error "--lang needs a language"
			lang=$2 lang_set=1
			shift
			;;
		--lang=*) lang=${1#--lang=} lang_set=1 ;;
		--from)
			[ $# -ge 2 ] || usage_error "--from needs <file>:<line>[-<line>]"
			from=$2 from_set=1
			shift
			;;
		--from=*) from=${1#--from=} from_set=1 ;;
		-h | --help)
			usage_text
			finish 0
			;;
		-*) usage_error "rule new: unknown option '$1'" ;;
		*)
			[ -z "$name" ] || usage_error "rule new takes one name, not '$name' and '$1'"
			name=$1
			;;
		esac
		shift
	done
	[ -n "$name" ] || usage_error "rule new needs the rule's name, in kebab-case"
	[[ $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || usage_error "rule new: '$name' is not kebab-case (lowercase words joined by -)"
	if [ "$lang_set" = 1 ] && ! [[ $lang =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
		usage_error "--lang: '$lang' is not the name of a language ast-grep knows"
	fi
	if [ "$from_set" = 1 ]; then
		[[ $from =~ ^(.+):([1-9][0-9]*)(-([1-9][0-9]*))?$ ]] || usage_error "--from takes <file>:<line>[-<line>], not '$from'"
		file=${BASH_REMATCH[1]} first=${BASH_REMATCH[2]} last=${BASH_REMATCH[4]:-${BASH_REMATCH[2]}}
		[ "$first" -le "$last" ] || usage_error "--from: the range $first-$last ends before it starts"
		if [ ! -f "$file" ] || [ ! -r "$file" ]; then die "--from: cannot read $file"; fi
		# Relative to the current directory, before moving to the repo root.
		tmp_file case_file
		from_case "$file" "$first" "$last" >"$case_file"
		if [ "$lang_set" = 0 ]; then lang=$(lang_of_file "$file"); fi
	fi
	load_config
	find_repo

	# The language: --lang, else --from's file's, else the repo's single enabled one.
	if [ -z "$lang" ] && [ ${#cfg_languages[@]} -eq 1 ]; then lang=${cfg_languages[0]}; fi
	if [ -z "$lang" ]; then
		local why="" of=" of assay's languages"
		if [ "$from_set" = 1 ]; then
			why="ast-grep gives $file no language, and "
			of=
		fi
		if [ ${#cfg_languages[@]} -eq 0 ]; then
			why+="the repo enables none$of"
		else
			printf -v list '%s, ' "${cfg_languages[@]}"
			why+="the repo enables several$of (${list%, })"
		fi
		die "rule new needs --lang <language>: $why"
	fi

	# Where the rule and its tests go: the first rule and test directories of the repo's sgconfig.yml, or the ones the
	# sgconfig.yml written here names.
	tmp_file dirs
	if [ -f sgconfig.yml ]; then
		sg_load || die "sgconfig.yml cannot be read as YAML: $sg_error"
		rule_dir=$(first_dir rules)
		test_dir=$(first_dir tests)
		[ -n "$rule_dir" ] || die "sgconfig.yml names no rule directory (ruleDirs), where the rule would go"
		[ -n "$test_dir" ] ||
			die "sgconfig.yml names no test directory (testConfigs: - testDir: <dir>), where the rule's tests would go"
		sg_dirs all >"$dirs"
	else
		rule_dir=rules test_dir=rule-tests
	fi
	local rule_file=$rule_dir/$name.yml test_file=$test_dir/$name-test.yml

	# A rule of that name: its files, or a rule of that id in any of the directories sgconfig.yml names.
	for f in "$rule_file" "$test_file"; do
		if [ -e "$f" ] || [ -L "$f" ]; then
			echo "assay: a rule named $name already exists: $f" >&2
			finish 1
		fi
	done
	while IFS= read -r -d '' d; do
		d=$(root_relative "$d")
		[ -d "$d" ] || continue
		hit=$(grep -rlE --include='*.yml' --include='*.yaml' "^id:[[:space:]]*[\"']?${name}[\"']?[[:space:]]*(#.*)?$" -- "$d" |
			LC_ALL=C sort | head -n 1) || true
		if [ -n "$hit" ]; then
			echo "assay: a rule named $name already exists: $hit" >&2
			finish 1
		fi
	done <"$dirs"

	if [ ! -e sgconfig.yml ]; then
		cat >sgconfig.yml <<'EOF' || die "cannot write sgconfig.yml"
# ast-grep's project configuration, written by `assay rule new`. Its paths are relative to this file. While it
# exists, the ast-grep check runs the rules and their tests (assay check ast-grep).
ruleDirs:
  - rules
testConfigs:
  - testDir: rule-tests
EOF
		created+=(sgconfig.yml)
	fi
	mkdir -p -- "$rule_dir" "$test_dir" || die "cannot create $rule_dir and $test_dir"
	{
		cat <<'EOF'
# A code rule: a check born from a correction, scaffolded by `assay rule new`; the assay-rule skill has the
# procedure. Until every placeholder is replaced, `assay check ast-grep` fails, so a half-written rule cannot be
# committed. Each comment says what the field under it must hold.
EOF
		printf 'id: %s\nlanguage: %s\n' "$name" "$lang"
		cat <<'EOF'
# Always error: a rule is a check, never a warning.
severity: error
# One line, shown at the location: what is wrong and what to do instead. In English, with no quote of the user.
message: "<fill in: what is wrong and what to do instead>"
# Why: the root cause, what goes wrong otherwise. Fix: the right change, concretely: the API, command or file to use.
# Not a fix: the known dodges (renaming, aliasing, casting, moving the call elsewhere, suppressing). The closing line
# stays as it is.
note: |
  Why: <fill in: the root cause>
  Fix: <fill in: the right change>
  Not a fix: <fill in: the known dodges>
  If the rule is wrong here, stop and tell the user; exceptions go in the rule's own file.
# The shape of the corrected code, and no wider: a pattern, or kind, has, inside, all, any. An exception is a not:
# clause here, never an inline ast-grep-ignore.
rule:
  pattern: "<fill in: the shape of the corrected code>"
# Files the rule does not apply to, as globs; existing occurrences that could not be verified go here, under a comment
# that marks them as existing occurrences.
# ignores:
#   - "<glob>"
# The rewrite to the fix, where it is mechanical: `ast-grep scan -U` applies it.
# fix: "<the fix>"
# A document in this repo that explains the rule (an ADR), if there is one.
# url: "<path in this repo>"
EOF
	} >"$rule_file" || die "cannot write $rule_file"
	created+=("$rule_file")
	{
		echo "# The tests of $rule_file, run by \`ast-grep test --skip-snapshot-tests\` (assay check ast-grep)."
		printf 'id: %s\n' "$name"
		echo "# At least one case the rule must report: the corrected code, cut down to the minimum."
		echo "invalid:"
		if [ -n "$from" ]; then
			cat -- "$case_file"
		else
			echo '  - "<fill in: the corrected code, cut down to the minimum>"'
		fi
		cat <<'EOF'
# At least one case the rule must let pass: the fix, and a near miss (the same words in a string or a comment, a
# similar call that is fine).
valid:
  - "<fill in: the fix>"
  - "<fill in: a near miss>"
EOF
	} >"$test_file" || die "cannot write $test_file"
	created+=("$test_file")
	# Each path as the caller names it: relative to their directory, or absolute outside the repo.
	for f in "${created[@]}"; do
		if [[ $f == /* ]]; then echo "$f"; else realpath -m -s --relative-to="$caller_dir" -- "$root/$f"; fi
	done
	finish 0
}

cmd_rule() {
	[ $# -ge 1 ] || usage_error "rule needs a subcommand: new"
	local sub=$1
	shift
	case $sub in
	new) rule_new "$@" ;;
	-h | --help)
		usage_text
		finish 0
		;;
	*) usage_error "no rule subcommand named '$sub' (new)" ;;
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

# report_path <coverage> <assay dir>: the path of a check's coverage report. $ASSAY_DIR (or ${ASSAY_DIR}) in it
# stands for assay's directory, and a relative path is taken from the repo root.
# shellcheck disable=SC2016 # the literal text $ASSAY_DIR
report_path() {
	local p=${1//'${ASSAY_DIR}'/"$2"}
	p=${p//'$ASSAY_DIR'/"$2"}
	if [[ $p != /* ]]; then p=$root/$p; fi
	echo "$p"
}

# measure <check> <report> <dir>: coverage of new code, for a check that passed. Runs diff-cover on the report
# against the base, with the PATH assay was called with, writing its console report to <dir>/<check>.txt. Sets note
# to what the check's line says about it, and returns 1 when the check fails on it: the new lines the report can
# cover are under new_code percent covered, the report is missing, or diff-cover cannot run.
measure() {
	local n=$1 report=$2 dir=$3 rc=0 total missed covered word counts
	if [ ! -f "$report" ]; then
		note="no coverage report at $report"
		return 1
	fi
	if ! mkdir -p "$dir"; then
		note="cannot create $dir"
		return 1
	fi
	word=$(shell_word "$report")
	{
		echo "\$ diff-cover $word --compare-branch=$base_sha --diff-range-notation=.. --include-untracked"
		PATH=$caller_path diff-cover "$report" --compare-branch="$base_sha" --diff-range-notation=.. \
			--include-untracked --format "json:$dir/$n.json" </dev/null 2>&1 || rc=$?
	} >"$dir/$n.txt"
	if [ "$rc" -eq 127 ]; then
		note="diff-cover not found"
		return 1
	elif [ "$rc" -ne 0 ]; then
		note="diff-cover exit $rc"
		return 1
	fi
	if ! counts=$(jq -r '"\(.total_num_lines) \(.total_num_violations)"' "$dir/$n.json" 2>/dev/null) ||
		! read -r total missed <<<"$counts" || ! [[ $total =~ ^[0-9]+$ && $missed =~ ^[0-9]+$ ]]; then
		note="cannot read diff-cover's report $dir/$n.json"
		return 1
	fi
	if [ "$total" -eq 0 ]; then
		note="new code: no lines to cover"
		return 0
	fi
	covered=$((total - missed))
	note="new code: $covered of $total lines covered"
	# Exact: covered / total >= new_code / 100, without rounding.
	if [ $((covered * 100)) -ge $((new_code * total)) ]; then return 0; fi
	note+=", $((covered * 100 / total))%, under $new_code%"
	return 1
}

# print_head <file>: the first 100 lines of a file, ending in a newline, and how many more it has.
print_head() {
	local lines last
	lines=$(wc -l <"$1") || die "cannot read $1"
	# Empty when the file ends in a newline.
	last=$(tail -c 1 "$1") || die "cannot read $1"
	if [ -n "$last" ]; then lines=$((lines + 1)); fi
	if [ "$lines" -eq 0 ]; then
		echo "(no output)"
		return 0
	fi
	head -n 100 "$1"
	if [ -n "$last" ] && [ "$lines" -le 100 ]; then echo; fi
	if [ "$lines" -gt 100 ]; then echo "[$((lines - 100)) more lines in the log]"; fi
}

run_checks() {
	local logdir=$gitdir/assay n log rc t0 now secs start i shown what lowered default note report
	local covdir=$gitdir/assay/coverage.tmp
	local -a skipped=()
	# why: what a failing check's lines say in parentheses; detail: the file its failure section shows instead of its
	# log (diff-cover's report).
	declare -A is_skipped=() why=() detail=()
	mkdir -p "$logdir" 2>/dev/null || die "cannot create $logdir"
	[ -w "$logdir" ] || die "cannot write to $logdir"
	rm -rf "$covdir"

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
	for i in "${!loose_kind[@]}"; do
		n=${loose_check[$i]}
		case ${loose_kind[$i]} in
		off) what="$n is off" ;;
		exec) what="$n runs the repo's own exec" ;;
		coverage)
			if [ -z "${c_coverage[$n]}" ]; then
				what="$n measures no coverage of new code"
			else
				what="$n reads another coverage report, ${c_coverage[$n]}"
			fi
			;;
		new-code)
			read -r lowered default <<<"${loose_value[$i]}"
			what="new code needs $lowered% coverage, not assay's $default%"
			;;
		setting) what="$n ${loose_value[$i]}" ;;
		esac
		echo "  loosening: $what: ${loose_reason[$i]//$'\n'/ }"
	done
	for n in "${skipped[@]}"; do
		echo "  skipped: $n (no ${c_requires[$n]})"
	done
	presets_behind

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
		report=
		# A report left by an earlier run never counts.
		if [ -n "${c_coverage[$n]}" ]; then
			report=$(report_path "${c_coverage[$n]}" "$logdir")
			rm -f "$report"
		fi
		PATH=$caller_path ASSAY_BASE=$base_sha ASSAY_DIR=$logdir "$BASH" -c "${c_exec[$n]}" </dev/null >"$log" 2>&1 ||
			rc=$?
		note=
		if [ "$rc" -eq 0 ] && [ -n "$report" ]; then
			if ! measure "$n" "$report" "$covdir"; then
				failed+=("$n")
				why[$n]=$note
			fi
			if [ -f "$covdir/$n.txt" ]; then
				{
					echo
					cat "$covdir/$n.txt"
				} >>"$log"
				detail[$n]=$covdir/$n.txt
			fi
		fi
		now_us
		fmt_secs secs $((now - t0))
		if [ "$rc" -eq 0 ] && [ -z "${why[$n]:-}" ]; then
			echo "ok   $n $secs${note:+ ($note)}"
		elif [ "$rc" -eq 0 ]; then
			echo "FAIL $n $secs (${why[$n]})"
		else
			failed+=("$n")
			why[$n]="exit $rc"
			if [ "$rc" -eq 127 ]; then
				echo "FAIL $n $secs (exit 127: tool not found)"
			else
				echo "FAIL $n $secs (exit $rc)"
			fi
		fi
	done
	now_us
	fmt_secs secs $((now - start))

	# Each failure: its command, the first 100 lines of its output (of diff-cover's report, when it failed on
	# coverage), and the path of its full log.
	for n in "${failed[@]}"; do
		log=$logdir/$n.log
		echo
		echo "--- FAIL $n (${why[$n]})"
		echo "\$ ${c_exec[$n]}"
		print_head "${detail[$n]:-$log}"
		echo "log: $log"
	done
	rm -rf "$covdir"

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

# What the delegating assay runs inside the repo's devenv, from the repo root: it records in the directory given first
# whether the devenv set ASSAY_CONFIG (assay's module does) and whether it handed over, then runs the repo's own
# assay from the caller's directory, given second, so that a path among the arguments means what the caller meant.
# Being the delegating assay's own code, it works whatever version of assay the repo pins.
# shellcheck disable=SC2016 # expanded by the bash that runs it
delegate_sh='tmp=$1 cwd=$2
shift 2
if [ -z "${ASSAY_CONFIG:-}" ]; then
  : >"$tmp/unadopted"
  exit 2
fi
: >"$tmp/started"
cd -- "$cwd" || exit 2
exec assay "$@"'

# delegate <command> [<arg>...]: outside the repo's devenv, run `assay <command> <arg>...` inside it, entered from the
# repo root, so that the version the repo pins decides. devenv runs with the caller's PATH, not assay's own tools.
delegate() {
	local rc=0 cwd=$PWD
	find_repo
	[ -f "$root/devenv.nix" ] || not_adopted "$root has no devenv.nix"
	PATH=$caller_path command -v devenv >/dev/null ||
		die "cannot find devenv on the PATH, which assay needs to run inside the repo's devenv"
	local delegate_tmp
	tmp_file delegate_tmp -d
	PATH=$caller_path devenv shell -- "$BASH" -c "$delegate_sh" assay "$delegate_tmp" "$cwd" "$@" || rc=$?
	if [ -e "$delegate_tmp/unadopted" ]; then not_adopted "the devenv of $root does not import assay's module"; fi
	# devenv itself failed (exit 1 on an evaluation error), which must not pass for a failing check.
	[ -e "$delegate_tmp/started" ] || die "devenv shell failed (exit $rc) before assay could run in the repo's devenv"
	case $rc in
	0 | 1 | 2 | 130) finish "$rc" ;;
	*) die "the repo's assay exited $rc" ;;
	esac
}

# The machine-level entrypoints: the agent guard and the global git hooks. They run outside any devenv, never
# delegate, and read one rule list, the JSON file given with --rules, which assay's home-manager module renders from
# programs.assay.rules. assay ships no rules.

# The rule list, validated whole and emitted as shell assignments (strings quoted with @sh) that end with
# rules_loaded=1. A rule's examples (deny, allow) are the check builder's: the entrypoints do not read them.
# shellcheck disable=SC2016 # jq's $variables, not the shell's
rules_jq='
def fail($m): "\($m)\n" | halt_error(1);
def text: type == "string" and length > 0;
def line: text and (test("\n") | not);
def rule_ok($i):
  (if (.name? | type) == "string" then .name else "#\($i + 1)" end) as $n
  | if type != "object" then fail("rule \($n): not an object")
  elif (.name | text | not) or (.name | test($name_re) | not) then fail("rule \($n): name must match \($name_re)")
  elif (.on | IN("command", "path", "commit-msg", "pre-push", "stop") | not) then
    fail("rule \($n): on must be command, path, commit-msg, pre-push or stop, not \(.on | tojson)")
  elif .on == "command" and (.match | type) != "object" then fail("rule \($n): match must be an ast-grep rule, an object")
  elif .on == "command" and (.match | has("rule")) and
    (.match | keys - ["rule", "constraints", "utils", "transform"] | length) > 0 then
    fail("rule \($n): a match with a rule key is a rule file body: rule, constraints, utils and transform only")
  elif .on != "command" and (.match | text | not) then fail("rule \($n): match must be a non-empty string")
  elif .on == "pre-push" and (.match | IN("agent-branch", "agents-md") | not) then
    fail("rule \($n): a pre-push rule matches agent-branch or agents-md, not \(.match | tojson)")
  elif .on == "stop" and .match != "unsaved-work" then
    fail("rule \($n): a stop rule matches unsaved-work, not \(.match | tojson)")
  elif (.message | line | not) then fail("rule \($n): message must be one non-empty line")
  elif .note != null and (.note | type) != "string" then fail("rule \($n): note must be a string")
  elif .who != null and (.who | IN("agents", "everyone") | not) then
    fail("rule \($n): who must be agents or everyone, not \(.who | tojson)")
  elif .cwd != null and (.on != "command" or (.cwd | text | not)) then
    fail("rule \($n): cwd belongs to a command rule, a glob or main-checkout")
  elif .fileContent != null and (.on != "command" or (.fileContent | text | not)) then
    fail("rule \($n): fileContent belongs to a command rule, a regex")
  else . end;
[inputs]
| if length != 1 then fail("expected one JSON document, found \(length)") else .[0] end
| if type != "object" then fail("not a JSON object")
  elif .version != 1 then fail("unknown version \(.version | tojson)")
  elif (.rules | type) != "array" then fail("rules must be an array")
  else .rules end
| . as $rules
| reduce range(0; length) as $i ({};
    ($rules[$i] | rule_ok($i)).name as $n
    | if has($n) then fail("two rules are named \($n)") else .[$n] = true end)
| ($rules[]
    | "r_name+=(\(.name | @sh)) r_on+=(\(.on | @sh)) r_who+=(\(.who // "agents" | @sh))",
      "r_match+=(\(if .on != "command" then .match elif .match | has("rule") then .match | tojson
        else {rule: .match} | tojson end | @sh))",
      "r_message+=(\(.message | @sh)) r_note+=(\(.note // "" | @sh))",
      "r_cwd+=(\(.cwd // "" | @sh)) r_file_content+=(\(.fileContent // "" | @sh))"),
  "rules_loaded=1"
'

r_name=()
r_on=()
r_who=()
r_match=()
r_message=()
r_note=()
r_cwd=()
r_file_content=()
rules_loaded=0
rules_file=

# parse_rules_option <command> <arg>...: --rules <file> first, as both entrypoints take it; sets rules_file and
# rest_args to the arguments after it.
rest_args=()
parse_rules_option() {
	local command=$1
	shift
	case ${1:-} in
	--rules)
		[ $# -ge 2 ] || usage_error "$command: --rules needs a file"
		rules_file=$2
		shift 2
		;;
	--rules=*)
		rules_file=${1#--rules=}
		shift
		;;
	*) usage_error "$command needs --rules <file>" ;;
	esac
	[ -n "$rules_file" ] || usage_error "$command: --rules needs a file"
	rest_args=("$@")
}

load_rules() {
	local out
	if [ ! -f "$rules_file" ] || [ ! -r "$rules_file" ]; then die "cannot read the rule list $rules_file"; fi
	if ! out=$(jq -n -r --arg name_re "$name_re" "$rules_jq" "$rules_file" 2>&1); then
		die "invalid rule list $rules_file: $out"
	fi
	eval "$out"
	[ "$rules_loaded" = 1 ] || die "invalid rule list $rules_file: incomplete"
}

# rule_runs <i>: rule <i> runs in this session: it binds everyone, or it binds agents and the agent marker is set.
rule_runs() { [ "${r_who[$1]}" = everyone ] || [ -n "${ASSAY_AGENT:-}" ]; }

# active_rules <on>: the indices of the rules on <on> that run in this session, in the list's order, in active.
active=()
active_rules() {
	local i
	active=()
	for i in "${!r_name[@]}"; do
		if [ "${r_on[$i]}" = "$1" ] && rule_runs "$i"; then active+=("$i"); fi
	done
}

# rule_text <i> [<detail>...]: what a violated rule says: its message, the details indented under it, then its note
# after a blank line.
rule_text() {
	local i=$1 d
	shift
	printf '%s\n' "${r_message[$i]}"
	for d in "$@"; do printf '  %s\n' "$d"; done
	if [ -n "${r_note[$i]}" ]; then printf '\n%s\n' "${r_note[$i]}"; fi
}

# The violated rules, in the list's order, each with its text.
violated=()
declare -A violated_text=()
# violate <i> [<detail>...]
violate() {
	local i=$1
	shift
	if [ -z "${violated_text[$i]+set}" ]; then violated+=("$i"); fi
	violated_text[$i]=$(rule_text "$i" "$@")
}
# violated_texts: every violated rule's text, a blank line between two.
violated_texts() {
	local i sep=
	for i in "${violated[@]}"; do
		printf '%s%s\n' "$sep" "${violated_text[$i]}"
		sep=$'\n'
	done
}

# The guard. The event, in Claude Code's hook JSON, emitted as shell assignments.
# shellcheck disable=SC2016 # jq's $variables, not the shell's
event_jq='
def fail($m): "\($m)\n" | halt_error(1);
def get(f): (try f catch null) | if type == "string" then . else "" end;
[inputs]
| if length != 1 then fail("expected one JSON document, found \(length)") else .[0] end
| if type != "object" then fail("the event is not a JSON object") else . end
| "ev_name=\(get(.hook_event_name) | @sh) ev_tool=\(get(.tool_name) | @sh) ev_cwd=\(get(.cwd) | @sh)",
  "ev_stop_active=\(if .stop_hook_active == true then 1 else 0 end)",
  "ev_command=\(get(.tool_input.command) | @sh)",
  "ev_path=\(get(.tool_input.file_path // .tool_input.notebook_path) | @sh)",
  "event_loaded=1"
'
ev_name=
ev_tool=
ev_cwd=
ev_stop_active=0
ev_command=
ev_path=
event_loaded=0

# glob_matches <glob> <absolute path>: `*` and `?` stay within a path component and `**` crosses them; `[...]` is a
# class (`[!...]` negated), and `\` makes the next character plain. A glob with no `/` matches the path's last
# component, one that starts with `/` the whole path, any other the path's end at a component boundary.
glob_matches() {
	local g=$1 path=$2 re="" c i j n=${#1} class
	for ((i = 0; i < n; i++)); do
		c=${g:i:1}
		case $c in
		'*')
			if [ "${g:i+1:1}" != '*' ]; then
				re+='[^/]*'
			elif [ "${g:i+2:1}" = / ]; then
				re+='(.*/)?'
				i=$((i + 2))
			else
				re+='.*'
				i=$((i + 1))
			fi
			;;
		'?') re+='[^/]' ;;
		'[')
			# The class ends at the first `]` after its first character.
			j=$((i + 2))
			while [ "$j" -lt "$n" ] && [ "${g:j:1}" != ']' ]; do j=$((j + 1)); done
			if [ "$j" -ge "$n" ]; then
				re+='\['
			else
				class=${g:i+1:j-i-1}
				if [[ $class == '!'* ]]; then class="^${class:1}"; fi
				re+="[$class]"
				i=$j
			fi
			;;
		\\)
			i=$((i + 1))
			c=${g:i:1}
			if [ -n "$c" ]; then re+="\\$c"; fi
			;;
		[.^\$+\(\)\{\}\|]) re+="\\$c" ;;
		*) re+=$c ;;
		esac
	done
	if [[ $g != */* ]]; then
		[[ ${path##*/} =~ ^$re$ ]]
	elif [[ $g == /* ]]; then
		[[ $path =~ ^$re$ ]]
	else
		[[ $path =~ (^|/)$re$ ]]
	fi
}

# in_main_checkout <absolute path>: the path is inside a main checkout: in its working tree, whose git dir is its
# common dir (a linked worktree's is not), or in the git dir of a repo that is not bare, which sits in its main
# checkout. A path that does not exist yet is judged by its nearest existing directory. Sets checkout_root to the
# checkout's top level.
checkout_root=
in_main_checkout() {
	local d=$1 out in_tree in_git_dir bare git_dir common_dir
	while [ ! -d "$d" ]; do
		d=${d%/*}
		if [ -z "$d" ]; then d=/; fi
	done
	out=$(git -C "$d" rev-parse --path-format=absolute --is-inside-work-tree --is-inside-git-dir \
		--is-bare-repository --git-dir --git-common-dir 2>/dev/null) || return 1
	{ read -r in_tree && read -r in_git_dir && read -r bare && read -r git_dir && read -r common_dir; } <<<"$out" ||
		return 1
	if [ "$in_tree" = true ]; then
		[ "$git_dir" = "$common_dir" ] || return 1
		checkout_root=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || return 1
	elif [ "$in_git_dir" = true ] && [ "$bare" = false ]; then
		checkout_root=${common_dir%/*}
	else
		return 1
	fi
}

# path_matches <glob or main-checkout> <path>: a path rule's match, or a command rule's cwd.
path_matches() {
	local abs
	[ -n "$2" ] || return 1
	abs=$(realpath -m -s -- "$2") || die "cannot resolve the path $2"
	if [ "$1" = main-checkout ]; then in_main_checkout "$abs"; else glob_matches "$1" "$abs"; fi
}

# guard_answer <decision>: print the answer for the violated rules, log one hit per rule, and exit 0.
guard_answer() {
	local decision=$1 reason i
	reason=$(violated_texts)
	case $decision in
	deny)
		jq -nc --arg r "$reason" \
			'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
		;;
	block) jq -nc --arg r "$reason" '{decision: "block", reason: $r}' ;;
	esac
	for i in "${violated[@]}"; do
		# shellcheck disable=SC2016 # jq's $variables, not the shell's
		log_hit guard '{event: $event, tool: (if $tool == "" then null else $tool end), rule: $rule, decision: $decision}' \
			--arg event "$ev_name" --arg tool "$ev_tool" --arg rule "${r_name[$i]}" --arg decision "$decision"
	done
	finish 0
}

# unquote_word <word>: a shell word as the shell would pass it, for the simple forms: quotes around it removed, a
# leading --option= cut off, and a leading ~/ expanded.
unquote_word() {
	local w=$1
	strip_quotes() {
		if [ ${#w} -ge 2 ] && { [[ $w == \"*\" ]] || [[ $w == \'*\' ]]; }; then w=${w:1:${#w}-2}; fi
	}
	strip_quotes
	if [[ $w == -*=* ]]; then
		w=${w#*=}
		strip_quotes
	fi
	if [[ $w == \~/* ]]; then w=$HOME/${w#\~/}; fi
	printf '%s' "$w"
}

# file_holds <word> <regex>: the file a command names with <word> holds text matching the regex. A file that cannot
# be read (missing, standard input, a variable) holds nothing.
file_holds() {
	local f rc=0
	f=$(unquote_word "$1")
	if [ -z "$f" ] || [ "$f" = - ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then return 1; fi
	jq -n -e --rawfile text "$f" --arg re "$2" '$text | test($re)' >/dev/null 2>&1 || rc=$?
	case $rc in
	0) return 0 ;;
	1) return 1 ;;
	*) die "cannot match $f against the regex $2" ;;
	esac
}

# guard_command: the command rules over the Bash tool's command, all at once through ast-grep.
guard_command() {
	local i inline="" sep="" out err file bound matches
	local -a matched=()
	active_rules command
	for i in "${active[@]}"; do
		if [ -n "${r_cwd[$i]}" ] && ! path_matches "${r_cwd[$i]}" "$ev_cwd"; then continue; fi
		# r_match holds a rule file's body, an object: the id, the language and the severity go first.
		inline+="$sep{\"id\": \"r$i\", \"language\": \"bash\", \"severity\": \"hint\", ${r_match[$i]:1}"
		sep=$'\n---\n'
	done
	if [ -z "$inline" ] || [ -z "$ev_command" ]; then finish 0; fi
	command -v ast-grep >/dev/null || die "cannot find ast-grep on the PATH"
	tmp_file err
	# From the root: ast-grep would read a project's sgconfig.yml in the cwd.
	out=$(cd / && printf '%s' "$ev_command" | ast-grep scan --inline-rules "$inline" --stdin --json=stream 2>"$err") ||
		die "ast-grep cannot match the command rules: $(<"$err")"
	# One record per match: the rule's index, whether it binds $FILE, and what.
	tmp_file matches
	jq -j '(.metaVariables.single.FILE // null) as $f
    | "\(.ruleId[1:])\u0000\(if $f then 1 else 0 end)\u0000\($f.text // "")\u0000"' <<<"$out" >"$matches" ||
		die "cannot read ast-grep's matches"
	while IFS= read -r -d '' i && IFS= read -r -d '' bound && IFS= read -r -d '' file; do
		if [ -n "${r_file_content[$i]}" ] && [ "$bound" = 1 ] && ! file_holds "$file" "${r_file_content[$i]}"; then continue; fi
		matched[i]=1
	done <"$matches"
	for i in "${!matched[@]}"; do violate "$i"; done
	if [ ${#violated[@]} -gt 0 ]; then guard_answer deny; fi
	finish 0
}

# guard_path: the path rules over the path an Edit, Write or NotebookEdit writes, relative to the cwd if it is not
# absolute.
guard_path() {
	local i abs
	[ -n "$ev_path" ] || finish 0
	abs=$(realpath -m -s -- "$ev_path") || die "cannot resolve the path $ev_path"
	active_rules path
	for i in "${active[@]}"; do
		if path_matches "${r_match[$i]}" "$abs"; then
			if [ "${r_match[$i]}" = main-checkout ]; then
				violate "$i" "$abs is in the main checkout $checkout_root"
			else
				violate "$i" "$abs"
			fi
		fi
	done
	if [ ${#violated[@]} -gt 0 ]; then guard_answer deny; fi
	finish 0
}

# unsaved_work: the cwd is in a worktree with uncommitted changes (untracked files included) or, when the repo has a
# remote, commits on no remote-tracking branch. Sets unsaved to what is unsaved, with the worktree's top level.
unsaved=
unsaved_work() {
	local top status n inside remotes
	local -a what=()
	inside=$(git rev-parse --is-inside-work-tree 2>/dev/null) || return 1
	[ "$inside" = true ] || return 1
	top=$(git rev-parse --show-toplevel) || die "cannot find the top level of $PWD"
	# No optional locks: the guard runs beside the agent's own git commands.
	status=$(git --no-optional-locks status --porcelain --untracked-files=normal) ||
		die "cannot read the status of $top"
	if [ -n "$status" ]; then what+=("uncommitted changes"); fi
	remotes=$(git remote) || die "cannot list the remotes of $top"
	if [ -n "$remotes" ] && git rev-parse -q --verify HEAD >/dev/null; then
		n=$(git rev-list --count HEAD --not --remotes) || die "cannot count the unpushed commits of $top"
		if [ "$n" -eq 1 ]; then
			what+=("1 commit on no remote")
		elif [ "$n" -gt 1 ]; then
			what+=("$n commits on no remote")
		fi
	fi
	[ ${#what[@]} -gt 0 ] || return 1
	unsaved="$top: ${what[0]}"
	if [ ${#what[@]} -gt 1 ]; then unsaved+=" and ${what[1]}"; fi
}

# guard_stop: the stop rules over the session's cwd, once per turn: Claude Code sets stop_hook_active when a Stop hook
# already kept the turn going.
guard_stop() {
	local i
	[ "$ev_stop_active" = 0 ] || finish 0
	[ -n "$ev_cwd" ] && [ -d "$ev_cwd" ] || finish 0
	active_rules stop
	for i in "${active[@]}"; do
		# unsaved-work, the only stop match.
		if unsaved_work; then violate "$i" "$unsaved"; fi
	done
	if [ ${#violated[@]} -gt 0 ]; then guard_answer block; fi
	finish 0
}

cmd_guard() {
	# The guard fails open: on its own error, exit 1, which Claude Code shows without blocking. Never 2, which blocks.
	error_exit=1
	local event
	parse_rules_option guard "$@"
	[ ${#rest_args[@]} -eq 0 ] || usage_error "guard: unexpected argument '${rest_args[0]}'"
	load_rules
	event=$(cat) || die "cannot read the event on stdin"
	local out
	out=$(jq -n -r "$event_jq" <<<"$event" 2>&1) || die "invalid event: $out"
	eval "$out"
	[ "$event_loaded" = 1 ] || die "invalid event: incomplete"
	# Paths and git's answers are the session's: its cwd, and no repository forced through the environment.
	unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
	if [ -n "$ev_cwd" ] && [ -d "$ev_cwd" ]; then cd "$ev_cwd" || die "cannot enter $ev_cwd"; fi
	case $ev_name in
	PreToolUse)
		case $ev_tool in
		Bash) guard_command ;;
		Edit | Write | NotebookEdit) guard_path ;;
		esac
		;;
	Stop) guard_stop ;;
	esac
	finish 0
}

# The global git hooks. Git appends the hook's own arguments to the command it is registered with, and runs it from
# the worktree's top level.

# hook_reject <hook>: print every violated rule on stderr, log one hit each, and exit 1.
hook_reject() {
	local hook=$1 i sep=
	for i in "${violated[@]}"; do
		printf '%sassay: %s: %s\n' "$sep" "${r_name[$i]}" "${violated_text[$i]}" >&2
		sep=$'\n'
	done
	for i in "${violated[@]}"; do
		# shellcheck disable=SC2016 # jq's $variables, not the shell's
		log_hit git-hook '{hook: $hook, rule: $rule}' --arg hook "$hook" --arg rule "${r_name[$i]}"
	done
	finish 1
}

# hook_commit_msg <message file>: the commit-msg rules' regexes over the message as git stores it: what follows the
# scissors line of `git commit --verbose` cut off, comments stripped.
hook_commit_msg() {
	[ $# -eq 1 ] || die "commit-msg takes the message file"
	local file=$1 msg i rc out
	active_rules commit-msg
	[ ${#active[@]} -gt 0 ] || finish 0
	if [ ! -f "$file" ] || [ ! -r "$file" ]; then die "cannot read the message $file"; fi
	msg=$(awk 'index($0, "------------------------ >8 ------------------------") { exit } { print }' "$file" |
		git stripspace --strip-comments) || die "cannot read the message $file"
	for i in "${active[@]}"; do
		rc=0
		out=$(jq -n -e --arg msg "$msg" --arg re "${r_match[$i]}" '$msg | test($re)' 2>&1) || rc=$?
		case $rc in
		0) violate "$i" ;;
		1) ;;
		*) die "rule ${r_name[$i]}'s regex cannot be used: $out" ;;
		esac
	done
	if [ ${#violated[@]} -gt 0 ]; then hook_reject commit-msg; fi
	finish 0
}

# remote_default_branch <remote> <url>: the remote's default branch, in remote_default: its HEAD as the last fetch
# saw it (refs/remotes/<remote>/HEAD), else as the remote says. An empty remote has none yet: remote_default stays
# empty and any branch may be its first.
remote_default=
remote_default_known=0
remote_default_branch() {
	local ref out re=$'(^|\n)ref: refs/heads/([^\t]+)\tHEAD(\n|$)'
	[ "$remote_default_known" = 0 ] || return 0
	if ref=$(git symbolic-ref -q "refs/remotes/$1/HEAD" 2>/dev/null); then
		remote_default=${ref#"refs/remotes/$1/"}
	elif ! out=$(git ls-remote --symref "$2" HEAD 2>&1); then
		die "cannot find the default branch of $1: ${out//$'\n'/ }"
	elif [[ $out =~ $re ]]; then
		remote_default=${BASH_REMATCH[2]}
	elif ! out=$(git ls-remote --heads "$2" 2>&1) || [ -n "$out" ]; then
		die "cannot find the default branch of $1: it names no HEAD"
	fi
	remote_default_known=1
}

# hook_pre_push <remote> <url>: the pre-push rules over the refs git pushes, given on stdin as
# "<local ref> <local oid> <remote ref> <remote oid>" lines.
# - agent-branch: every pushed refs/heads/* (a deletion too) is agent/* or the remote's default branch; tags and other
#   refs pass.
# - agents-md: every pushed branch tip's tree has the AGENTS.md / CLAUDE.md shape (agents_md_problems).
hook_pre_push() {
	[ $# -ge 1 ] && [ $# -le 2 ] || die "pre-push takes the remote's name and URL"
	local remote=$1 url=${2:-$1} lref loid rref i pushed problem problems
	local -a lines=() details=()
	active_rules pre-push
	[ ${#active[@]} -gt 0 ] || finish 0
	tmp_file problems
	while read -r lref loid rref _ || [ -n "$lref" ]; do
		if [ -n "$rref" ]; then lines+=("$loid $rref"); fi
	done
	for i in "${active[@]}"; do
		details=()
		for pushed in "${lines[@]}"; do
			loid=${pushed%% *} rref=${pushed#* }
			[[ $rref == refs/heads/* ]] || continue
			case ${r_match[$i]} in
			agent-branch)
				if [[ $rref == refs/heads/agent/* ]]; then continue; fi
				remote_default_branch "$remote" "$url"
				if [ -z "$remote_default" ] || [ "$rref" = "refs/heads/$remote_default" ]; then continue; fi
				details+=("$rref")
				;;
			agents-md)
				if [[ $loid =~ ^0+$ ]]; then continue; fi
				# In this shell, so that a tree it cannot read stops the hook.
				agents_md_problems "$loid" >"$problems" || true
				while IFS= read -r problem; do
					details+=("$rref: $problem")
				done <"$problems"
				;;
			esac
		done
		if [ ${#details[@]} -gt 0 ]; then violate "$i" "${details[@]}"; fi
	done
	if [ ${#violated[@]} -gt 0 ]; then hook_reject pre-push; fi
	finish 0
}

cmd_git_hook() {
	# The git hooks fail closed: when they cannot evaluate their rules they exit 1, as for a violated rule. They stand
	# only in front of commits and pushes, and a person can still bypass them.
	error_exit=1
	die_prefix="cannot evaluate rules: "
	parse_rules_option git-hook "$@"
	set -- "${rest_args[@]}"
	[ $# -ge 1 ] || usage_error "git-hook needs the hook's name"
	local hook=$1
	shift
	case $hook in
	commit-msg | pre-push) ;;
	*) die "no hook named '$hook' (commit-msg or pre-push)" ;;
	esac
	load_rules
	case $hook in
	commit-msg) hook_commit_msg "$@" ;;
	pre-push) hook_pre_push "$@" ;;
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
	preset)
		shift
		if [ -z "${ASSAY_CONFIG:-}" ]; then delegate preset "$@"; fi
		cmd_preset "$@"
		;;
	findings)
		shift
		if [ -z "${ASSAY_CONFIG:-}" ]; then delegate findings "$@"; fi
		cmd_findings "$@"
		;;
	rule)
		shift
		if [ -z "${ASSAY_CONFIG:-}" ]; then delegate rule "$@"; fi
		cmd_rule "$@"
		;;
	# The machine-level subcommands run outside any devenv and never delegate.
	guard)
		shift
		cmd_guard "$@"
		;;
	git-hook)
		shift
		cmd_git_hook "$@"
		;;
	collect) not_yet collect "--db <file>    the nightly collector" ;;
	-h | --help | help)
		usage_text
		finish 0
		;;
	*) usage_error "unknown command '$1'" ;;
	esac
}

main "$@"
