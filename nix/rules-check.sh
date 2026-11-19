#!/usr/bin/env bash
# assay's check of a rule list, which the flake's check builder (lib.rulesCheck) runs: every example of a rendered
# rule list (programs.assay.rulesFile) fed to the real entrypoint its rule's `on` names, with that rule alone, in a
# fresh fixture, with ASSAY_AGENT set for a rule that binds agents and unset for one that binds everyone. A deny
# example must be denied (a PreToolUse deny, a Stop block, a hook's exit 1) and an allow example must pass.
#
# usage: rules-check.sh <rules file>, with assay, git and jq on the PATH. Prints one line per example, then a count;
# exits 1 when an example is not as expected, when an entrypoint fails on one, or when the list cannot be used.
#
# The fixture, under a root that is an example's default cwd and is in no repository:
#   origin.git  a bare remote whose default branch is main
#   repo/       its clone, a main checkout on main, pushed; its files have the AGENTS.md / CLAUDE.md shape
#   worktree/   a linked worktree of repo on agent/example, pushed, its upstream set
#   local/      a repo with one commit and no remote
set -euo pipefail

rules=${1:?usage: rules-check.sh <rules file>}
zero=0000000000000000000000000000000000000000

fail() {
	echo "rules check: $*" >&2
	exit 1
}
[ -f "$rules" ] && [ -r "$rules" ] || fail "cannot read $rules"
for tool in assay git jq; do command -v "$tool" >/dev/null || fail "cannot find $tool on the PATH"; done

# What an example of each kind of rule holds: its fields and their types; the first is the one a string stands for,
# which the home-manager module writes as an object already.
# shellcheck disable=SC2016 # jq's $variables, not the shell's
validate='
def fail($m): "\($m)\n" | halt_error(1);
def fields:
  {command: {command: "string", cwd: "string", files: "object"},
   path: {path: "string", cwd: "string"},
   "commit-msg": {message: "string"},
   "pre-push": {ref: "string", files: "object"},
   stop: {uncommitted: "boolean", unpushed: "boolean", remote: "boolean"}};
def required: {command: "command", path: "path", "commit-msg": "message"};
def example_ok($on; $where):
  if type != "object" then fail("\($where): an example is an object")
  else
    (to_entries[] as $f
     | (fields[$on][$f.key] // null) as $type
     | if $type == null then fail("\($where): \($on) examples have no field \($f.key)")
       elif ($f.value | type) != $type then fail("\($where): \($f.key) must be a \($type)")
       elif $f.key == "files" and ($f.value | [.[] | type] - ["string", "null"] | length) > 0 then
         fail("\($where): each file holds a string, or null")
       else empty end),
    ((required[$on] // null) as $field
     | if $field != null and (has($field) | not) then fail("\($where): no \($field)") else empty end)
  end;
[inputs]
| if length != 1 then fail("expected one JSON document") else .[0] end
| if type != "object" or .version != 1 or (.rules | type) != "array" then
    fail("not a rule list of version 1")
  else . end
| .rules[]
| . as $r
| (if (.name | type) != "string" or (fields | has($r.on | tostring) | not) then fail("a rule without a name or an on")
   else empty end),
  (("deny", "allow") as $k
   | if ($r[$k] | type) != "array" or ($r[$k] | length) == 0 then fail("rule \($r.name): no \($k) example")
     else $r[$k] | to_entries[] | .value | example_ok($r.on; "rule \($r.name), \($k) example \(.key + 1)") end)
'
out=$(jq -n "$validate" "$rules" 2>&1) || fail "$rules: $out"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home GIT_CONFIG_GLOBAL=$work/gitconfig GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES=$work
unset ASSAY_AGENT ASSAY_HITS_LOG GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
{
	mkdir -p "$HOME" &&
		git config --global user.name assay &&
		git config --global user.email assay@example.com &&
		git config --global init.defaultBranch main &&
		git config --global advice.detachedHead false &&
		git config --global gc.auto 0
} || fail "cannot set up git in $work"

# The fixture, built once and copied for each example: its linked worktree records relative paths, so that a copy
# is a fixture of its own. Every failure is checked by hand: the examples run inside a `||` list, where `set -e`
# does not hold.
template=$work/template
mkdir "$template"
{
	git init --quiet --bare "$template/origin.git" &&
		git clone --quiet "$template/origin.git" "$template/repo" &&
		printf '# repo\n\n## Related repos\n\nNone.\n' >"$template/repo/AGENTS.md" &&
		echo '@AGENTS.md' >"$template/repo/CLAUDE.md" &&
		git -C "$template/repo" add -A &&
		git -C "$template/repo" commit --quiet -m init &&
		git -C "$template/repo" push --quiet origin main &&
		git -C "$template/repo" remote set-head origin main &&
		git -C "$template/repo" worktree add --quiet --relative-paths ../worktree -b agent/example &&
		git -C "$template/worktree" push --quiet -u origin agent/example &&
		git init --quiet "$template/local" &&
		git -C "$template/local" commit --quiet --allow-empty -m init
} </dev/null >"$work/err" 2>&1 || fail "cannot build the fixture: $(<"$work/err")"

# fixture: a fresh copy of the fixture, its root in `root`.
examples=0
fixture() {
	examples=$((examples + 1))
	root=$work/example$examples
	cp -a "$template" "$root" || fail "cannot copy the fixture to $root"
}

# file_entries <files object> <file>: each file as two NUL-terminated records written to <file>, its path and its
# content; \x01 for null.
file_entries() {
	jq -j 'to_entries[] | "\(.key)\u0000\(.value // "\u0001")\u0000"' <<<"$1" >"$2" || fail "cannot read the files $1"
}

# write_files <dir> <files object>: each file under the directory, with its content; null removes it.
write_files() {
	local dir=$1 path content
	file_entries "$2" "$work/files.entries"
	while IFS= read -r -d '' path && IFS= read -r -d '' content; do
		if [ "$content" = $'\x01' ]; then
			rm -f -- "$dir/$path" || fail "cannot remove $dir/$path"
		else
			{ mkdir -p -- "$(dirname -- "$dir/$path")" && printf '%s' "$content" >"$dir/$path"; } ||
				fail "cannot write $dir/$path"
		fi
	done <"$work/files.entries"
}

# tip_with <files object>: a commit on the worktree's HEAD whose tree has the files over HEAD's, null removing one.
tip_with() {
	local path content blob tree
	local -x GIT_INDEX_FILE=$work/index
	rm -f "$GIT_INDEX_FILE"
	git -C "$root/worktree" read-tree HEAD || return 1
	file_entries "$1" "$work/tip.entries"
	while IFS= read -r -d '' path && IFS= read -r -d '' content; do
		if [ "$content" = $'\x01' ]; then
			git -C "$root/worktree" update-index --force-remove -- "$path" || return 1
		else
			blob=$(printf '%s' "$content" | git -C "$root/worktree" hash-object -w --stdin) &&
				git -C "$root/worktree" update-index --add --cacheinfo "100644,$blob,$path" || return 1
		fi
	done <"$work/tip.entries"
	tree=$(git -C "$root/worktree" write-tree) &&
		git -C "$root/worktree" commit-tree "$tree" -p HEAD -m example
}

# guard_says <event>: run assay guard over the event; sets answer (the reason, empty when allowed). Returns 2 when the
# guard fails, with its error in answer.
guard_says() {
	local out rc=0
	out=$(assay guard --rules "$one_rule" <<<"$1" 2>"$work/err") || rc=$?
	if [ "$rc" -ne 0 ]; then
		answer="assay guard exited $rc: $(head -n 1 "$work/err")"
		return 2
	fi
	answer=$(jq -r '.hookSpecificOutput.permissionDecisionReason // .reason // empty' <<<"${out:-null}" 2>/dev/null) ||
		answer="an answer that is not JSON: $out"
	if [ -n "$out" ] && [ -z "$answer" ]; then answer="an answer with no reason: $out"; fi
}

# hook_says <dir> <hook> <arg>...: run assay git-hook from the directory, its stdin this function's; sets answer.
# Returns 2 when the hook cannot evaluate its rules or fails otherwise.
hook_says() {
	local dir=$1 rc=0
	shift
	(cd "$dir" && assay git-hook --rules "$one_rule" "$@") >"$work/out" 2>"$work/err" || rc=$?
	answer=$(head -n 1 "$work/err")
	if [ "$rc" -eq 1 ] && [ -n "$answer" ] && [[ $answer != "assay: cannot evaluate rules:"* ]] &&
		[ ! -s "$work/out" ]; then
		return 0
	fi
	if [ "$rc" -eq 0 ] && [ ! -s "$work/err" ] && [ ! -s "$work/out" ]; then return 0; fi
	answer="assay git-hook exited $rc: $answer"
	return 2
}

# run_example <on> <example>: the example through its entrypoint in a fresh fixture; sets answer (empty when allowed).
run_example() {
	local on=$1 ex=$2 cwd files event flags remote uncommitted unpushed file tip ref
	fixture
	answer=
	case $on in
	command | path)
		{
			cwd=$(jq -r --arg root "$root" '.cwd // "." | if startswith("/") then . else "\($root)/\(.)" end' <<<"$ex") &&
				files=$(jq -c '.files // {}' <<<"$ex") &&
				event=$(jq -c --arg d "$cwd" --arg tool "$on" '
            if $tool == "command" then {tool_name: "Bash", tool_input: {command: .command}}
            else {tool_name: "Edit", tool_input: {file_path: .path}} end
            | {hook_event_name: "PreToolUse"} + . + {cwd: $d}' <<<"$ex")
		} || fail "cannot read the example $ex"
		mkdir -p -- "$cwd" || fail "cannot create $cwd"
		write_files "$cwd" "$files"
		guard_says "$event"
		;;
	stop)
		flags=$(jq -r '[.remote != false, .uncommitted == true, .unpushed == true] | @tsv' <<<"$ex") ||
			fail "cannot read the example $ex"
		read -r remote uncommitted unpushed <<<"$flags"
		if [ "$remote" = true ]; then cwd=$root/worktree; else cwd=$root/local; fi
		if [ "$uncommitted" = true ]; then
			echo draft >"$cwd/uncommitted.txt" || fail "cannot write $cwd/uncommitted.txt"
		fi
		if [ "$unpushed" = true ]; then
			git -C "$cwd" commit --quiet --allow-empty -m unpushed || fail "cannot commit in $cwd"
		fi
		event=$(jq -nc --arg d "$cwd" '{hook_event_name: "Stop", cwd: $d, stop_hook_active: false}') ||
			fail "cannot write the Stop event"
		guard_says "$event"
		;;
	commit-msg)
		file=$root/COMMIT_EDITMSG
		jq -j '.message' <<<"$ex" >"$file" || fail "cannot write $file"
		hook_says "$root/repo" commit-msg "$file" </dev/null
		;;
	pre-push)
		{ files=$(jq -c '.files // {}' <<<"$ex") && ref=$(jq -r '.ref // "refs/heads/agent/example"' <<<"$ex"); } ||
			fail "cannot read the example $ex"
		# tip_with reports its failure through its status, which this turns into fail.
		# shellcheck disable=SC2310
		tip=$(tip_with "$files") || fail "cannot build the pushed tip"
		hook_says "$root/worktree" pre-push origin "$root/origin.git" <<<"refs/heads/agent/example $tip $ref $zero"
		;;
	esac
}

# summary <on> <example>: the example on one line, at most 100 characters.
summary() {
	local s
	s=$(jq -r --arg on "$1" '
    def one: gsub("\n"; "\\n");
    if $on == "command" then .command + (if .cwd then " (in \(.cwd))" else "" end)
    elif $on == "path" then .path + (if .cwd then " (in \(.cwd))" else "" end)
    elif $on == "commit-msg" then .message
    elif $on == "pre-push" and (keys == ["ref"]) then .ref
    else tojson end | one' <<<"$2")
	if [ ${#s} -gt 100 ]; then s="${s:0:97}..."; fi
	printf '%s' "$s"
}

count_rules=0 count=0 failed=0
jq -c '.rules[]' "$rules" >"$work/rules" || fail "cannot read the rules of $rules"
# The list with the current rule alone, which the entrypoints read.
one_rule=$work/rule.json
while IFS= read -r -u 4 rule; do
	count_rules=$((count_rules + 1))
	{
		name=$(jq -r '.name' <<<"$rule") && on=$(jq -r '.on' <<<"$rule") && who=$(jq -r '.who // "agents"' <<<"$rule") &&
			jq -c '{version: 1, rules: [.]}' <<<"$rule" >"$one_rule"
	} || fail "cannot read the rule $rule"
	if [ "$who" = agents ]; then
		export ASSAY_AGENT=assay-rules-check
	else
		unset ASSAY_AGENT
	fi
	for kind in deny allow; do
		jq -c --arg k "$kind" '.[$k][]' <<<"$rule" >"$work/examples" || fail "cannot read the $kind examples of $name"
		n=0
		# On descriptor 3, which nothing an example runs reads.
		while IFS= read -r -u 3 ex; do
			n=$((n + 1))
			count=$((count + 1))
			what=$(summary "$on" "$ex")
			rc=0
			# run_example reports its failure through fail or its status, which this keeps.
			# shellcheck disable=SC2310
			run_example "$on" "$ex" || rc=$?
			if [ "$rc" -ne 0 ]; then
				echo "FAIL $name $kind $n: $what: $answer"
				failed=$((failed + 1))
			elif [ "$kind" = deny ] && [ -z "$answer" ]; then
				echo "FAIL $name $kind $n: $what: passes"
				failed=$((failed + 1))
			elif [ "$kind" = allow ] && [ -n "$answer" ]; then
				echo "FAIL $name $kind $n: $what: denied: ${answer%%$'\n'*}"
				failed=$((failed + 1))
			else
				echo "ok   $name $kind $n: $what"
			fi
		done 3<"$work/examples"
	done
done 4<"$work/rules"

if [ "$failed" -eq 0 ]; then
	echo "rules check: $count_rules rules, $count examples, all as expected"
else
	echo "rules check: $count_rules rules, $count examples, $failed not as expected"
	exit 1
fi
