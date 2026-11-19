# shellcheck disable=SC2030,SC2031 # bats runs each test in a process of its own: what one test sets, no other reads
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# The hits log: one JSON line per `assay check` run, appended to ASSAY_HITS_LOG when it is set.

# hit_line <n>: the hits log's line <n>.
hit_line() { sed -n "$1p" "$ASSAY_HITS_LOG"; }
# hit <n> <jq argument>...: jq -e, with these arguments, over the hits log's line <n>.
hit() {
	local line
	line=$(hit_line "$1")
	shift
	jq -e "$@" <<<"$line"
}
# logged <n>: the hits log has <n> lines.
logged() {
	local n
	n=$(wc -l <"$ASSAY_HITS_LOG")
	[ "$n" -eq "$1" ]
}

@test "each assay check run appends one check line with the common fields and the run's" {
	local_repo
	check a true --fast
	check b "exit 1"
	export ASSAY_HITS_LOG=$T/state/assay/hits.jsonl
	run "$assay" check
	[ "$status" -eq 1 ]
	logged 1
	repo=$(pwd -P)
	line=$(hit_line 1)
	jq -e --arg repo "$repo" '
    (keys == ["agent", "exit", "failed", "mode", "only", "repo", "seconds", "source", "time", "v"])
    and .v == 1
    and (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .source == "check" and .repo == $repo and .agent == null
    and .mode == "full" and .only == [] and (.seconds | type) == "number" and .seconds >= 0
    and .failed == ["b"] and .exit == 1' <<<"$line"
	ASSAY_AGENT=claude-code run "$assay" check --fast a
	[ "$status" -eq 0 ]
	logged 2
	hit 2 '.agent == "claude-code" and .mode == "fast" and .only == ["a"] and .failed == [] and .exit == 0'
}

@test "repo is the main checkout, from a worktree too; only is the names as given" {
	local_repo
	check a true
	check c true
	git worktree add --quiet "$T/wt" -b topic
	cd "$T/wt"
	export ASSAY_HITS_LOG=$T/hits.jsonl ASSAY_AGENT=
	run "$assay" check c a c
	[ "$status" -eq 0 ]
	repo=$(cd "$T/work" && pwd -P)
	line=$(hit_line 1)
	jq -e --arg repo "$repo" '.repo == $repo and .only == ["c", "a", "c"] and .agent == null' <<<"$line"
}

@test "a run that exits 2 appends its line too; --list, usage errors and help append nothing" {
	local_repo
	git branch --quiet -m main trunk
	check a true
	export ASSAY_HITS_LOG=$T/hits.jsonl
	run "$assay" check
	[ "$status" -eq 2 ]
	run "$assay" check nope
	[ "$status" -eq 2 ]
	logged 2
	hit 1 '.exit == 2 and .failed == [] and .only == []'
	hit 2 '.exit == 2 and .only == ["nope"]'
	run "$assay" check --list
	run "$assay" check --nope
	run "$assay" check --help
	run "$assay" --help
	logged 2
}

@test "outside the devenv, the run writes one line: the repo's assay writes it, the delegating one nothing" {
	local_repo
	devenv_files yes
	check a "exit 1"
	outside_devenv
	export ASSAY_HITS_LOG=$T/hits.jsonl
	run "$assay" check
	[ "$status" -eq 1 ]
	logged 1
	hit 1 '.failed == ["a"] and .exit == 1'
	rm devenv.nix
	run "$assay" check
	[ "$status" -eq 2 ]
	logged 1
}

@test "with ASSAY_HITS_LOG unset or unwritable, nothing is written and the run is the same" {
	local_repo
	check fails "echo no; exit 1"
	check passes true
	untimed() { sed -E 's/ [0-9]+\.[0-9]{2}s/ Ns/g' <<<"$1"; }
	run --separate-stderr "$assay" check
	[ "$status" -eq 1 ]
	expected_out=$(untimed "$output") expected_err=$stderr
	touch "$T/file"
	mkdir "$T/readonly"
	chmod 555 "$T/readonly"
	for log in "$T/file/hits.jsonl" "$T" "$T/readonly/hits.jsonl"; do
		run --separate-stderr env ASSAY_HITS_LOG="$log" "$assay" check
		echo "$log: $status"
		[ "$status" -eq 1 ]
		actual_out=$(untimed "$output")
		[ "$actual_out" = "$expected_out" ]
		[ "$stderr" = "$expected_err" ]
	done
	uid=$(id -u)
	if [ "$uid" -ne 0 ]; then
		left=$(ls "$T/readonly")
		[ -z "$left" ]
	fi
	changes=$(git status --porcelain)
	[ -z "$changes" ]
}

@test "an unexpected failure's line has exit 2" {
	local_repo
	check fails "echo output; exit 1"
	mkdir "$T/bin"
	printf '#!/bin/sh\nexit 1\n' >"$T/bin/head"
	chmod +x "$T/bin/head"
	export ASSAY_HITS_LOG=$T/hits.jsonl
	run env PATH="$T/bin:$PATH" "$assay" check
	[ "$status" -eq 2 ]
	hit 1 '.exit == 2 and .failed == ["fails"]'
}

# common_fields <n> <source>: the hits log's line <n> has the fields every line has, for the source, the agent
# claude-code and the repo $T/repo.
common_fields() {
	local line repo
	line=$(hit_line "$1")
	repo=$(cd "$T/repo" && pwd -P)
	jq -e --arg s "$2" --arg repo "$repo" '
    .v == 1 and (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .source == $s and .repo == $repo and .agent == "claude-code"' <<<"$line"
}

@test "the guard appends one line per denied rule and per block; an allowed call writes nothing" {
	checkouts
	# shellcheck disable=SC2119 # no rule names: the whole example list
	example_rules
	export ASSAY_HITS_LOG=$T/hits.jsonl ASSAY_AGENT=claude-code
	bash() { jq -nc --arg c "$1" --arg d "$2" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}'; }
	event=$(bash 'git status' "$T/worktree")
	run "$assay" guard --rules "$RULES" <<<"$event"
	[ "$status" -eq 0 ]
	[ ! -e "$ASSAY_HITS_LOG" ]
	# Two rules at once: one line each, in the list's order.
	mkdir "$T/repo/sub"
	event=$(bash 'git commit -m x && git clone y' "$T/repo/sub")
	run "$assay" guard --rules "$RULES" <<<"$event"
	[ "$status" -eq 0 ]
	logged 2
	common_fields 1 guard
	hit 1 '(keys == ["agent", "decision", "event", "repo", "rule", "source", "time", "tool", "v"])
    and .event == "PreToolUse" and .tool == "Bash" and .rule == "no-clone" and .decision == "deny"'
	hit 2 '.rule == "main-checkout-commit" and .decision == "deny"'
	event=$(jq -nc --arg p "$T/repo/x" --arg d "$T/repo" \
		'{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $p}, cwd: $d}')
	run "$assay" guard --rules "$RULES" <<<"$event"
	hit 3 '.event == "PreToolUse" and .tool == "Write" and .rule == "main-checkout-edit" and .decision == "deny"'
	echo draft >"$T/repo/draft.txt"
	event=$(jq -nc --arg d "$T/repo" '{hook_event_name: "Stop", cwd: $d}')
	run "$assay" guard --rules "$RULES" <<<"$event"
	logged 4
	common_fields 4 guard
	hit 4 '.event == "Stop" and .tool == null and .rule == "save-work" and .decision == "block"'
	event=$(jq -nc --arg d "$T/repo" '{hook_event_name: "Stop", cwd: $d, stop_hook_active: true}')
	run "$assay" guard --rules "$RULES" <<<"$event"
	logged 4
}

@test "the git hooks append one line per rejected rule; an accepted commit or push writes nothing" {
	checkouts
	# shellcheck disable=SC2119 # no rule names: the whole example list
	example_rules
	export ASSAY_HITS_LOG=$T/hits.jsonl ASSAY_AGENT=claude-code
	cd "$T/repo"
	printf 'Fix\n' >"$T/msg"
	run "$assay" git-hook --rules "$RULES" commit-msg "$T/msg"
	[ "$status" -eq 0 ]
	[ ! -e "$ASSAY_HITS_LOG" ]
	printf 'Fix\n\nCo-Authored-By: A\n' >"$T/msg"
	run "$assay" git-hook --rules "$RULES" commit-msg "$T/msg"
	[ "$status" -eq 1 ]
	logged 1
	common_fields 1 git-hook
	hit 1 '(keys == ["agent", "hook", "repo", "rule", "source", "time", "v"])
    and .hook == "commit-msg" and .rule == "no-coauthor"'
	# The tip of main lacks AGENTS.md: a push of it to topic breaks two rules.
	head=$(git rev-parse HEAD)
	run "$assay" git-hook --rules "$RULES" pre-push origin "$T/origin.git" <<<"refs/heads/main $head refs/heads/topic $head"
	[ "$status" -eq 1 ]
	logged 3
	hit 2 '.hook == "pre-push" and .rule == "agent-branch"'
	hit 3 '.hook == "pre-push" and .rule == "agents-md-shape"'
	printf '# repo\n\n## Related repos\n\nNone.\n' >AGENTS.md
	echo '@AGENTS.md' >CLAUDE.md
	git add AGENTS.md CLAUDE.md
	git commit --quiet -m shape
	head=$(git rev-parse HEAD)
	run "$assay" git-hook --rules "$RULES" pre-push origin "$T/origin.git" <<<"refs/heads/main $head refs/heads/main $head"
	[ "$status" -eq 0 ]
	logged 3
}

@test "an unwritable hits log changes no answer of the guard or the git hooks" {
	checkouts
	# shellcheck disable=SC2119 # no rule names: the whole example list
	example_rules
	export ASSAY_AGENT=claude-code
	touch "$T/file"
	event=$(jq -nc --arg d "$T" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "git clone x"}, cwd: $d}')
	printf 'Fix\n\nCo-Authored-By: A\n' >"$T/msg"
	for log in "" "$T/file/hits.jsonl" "$T"; do
		run --separate-stderr env ASSAY_HITS_LOG="$log" "$assay" guard --rules "$RULES" <<<"$event"
		[ "$status" -eq 0 ]
		[ -z "$stderr" ]
		jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output"
		run --separate-stderr env ASSAY_HITS_LOG="$log" "$assay" git-hook --rules "$RULES" commit-msg "$T/msg"
		[ "$status" -eq 1 ]
		[ "$stderr" = "assay: no-coauthor: A commit names no co-author: remove the Co-Authored-By trailer." ]
	done
}
