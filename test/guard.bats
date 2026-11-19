# shellcheck disable=SC2030,SC2031 # bats runs each test in a process of its own: what one test sets, no other reads
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# assay guard: one hook event on stdin, in Claude Code's hook JSON; allow (no output), deny (PreToolUse) or block
# (Stop). The rules come from test/rules/example.json, which the home-manager module renders from
# test/rules/example.nix.

# guard <event JSON>: run assay guard over it, stdout and stderr apart.
guard() { run --separate-stderr "$assay" guard --rules "$RULES" <<<"$1"; }
# bash_event <command> [<cwd>]; edit_event <path> [<cwd>] [<tool>]; stop_event <cwd> [<stop_hook_active>]
bash_event() {
	jq -nc --arg c "$1" --arg d "${2:-$PWD}" \
		'{session_id: "s", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}'
}
edit_event() {
	local key=file_path
	if [ "${3:-Edit}" = NotebookEdit ]; then key=notebook_path; fi
	jq -nc --arg p "$1" --arg d "${2:-$PWD}" --arg t "${3:-Edit}" --arg k "$key" \
		'{hook_event_name: "PreToolUse", tool_name: $t, tool_input: {($k): $p, content: "x"}, cwd: $d}'
}
stop_event() {
	jq -nc --arg d "$1" --argjson a "${2:-false}" '{hook_event_name: "Stop", cwd: $d, stop_hook_active: $a}'
}
# guard_bash, guard_edit, guard_stop <argument>...: guard over the event that bash_event, edit_event or stop_event
# builds from the arguments.
guard_bash() {
	local event
	event=$(bash_event "$@")
	guard "$event"
}
guard_edit() {
	local event
	event=$(edit_event "$@")
	guard "$event"
}
guard_stop() {
	local event
	event=$(stop_event "$@")
	guard "$event"
}

# denied_by <message>...: the guard denied, with a reason that holds each message given.
denied_by() {
	echo "status $status, stdout: $output, stderr: $stderr"
	[ "$status" -eq 0 ]
	jq -e '.hookSpecificOutput | .hookEventName == "PreToolUse" and .permissionDecision == "deny"' <<<"$output"
	local reason m
	reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
	for m in "$@"; do [[ $reason == *"$m"* ]]; done
}
# allowed: no output, exit 0.
allowed() {
	echo "status $status, stdout: $output, stderr: $stderr"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

no_clone='Get repos and worktrees through the workspace tool, not git clone or git worktree.'

@test "a command rule matches the command's structure, not its text" {
	cd "$T"
	example_rules
	export ASSAY_AGENT=claude-code
	# shellcheck disable=SC2016 # the commands are literal text: the guard reads them, nothing expands them
	for c in 'cd x && git clone y' 'git -C r worktree add ../x' 'git -c x=y clone z' 'echo $(git clone x)' \
		'FOO=1 git clone x' $'cd x\ngit clone y'; do
		guard_bash "$c"
		denied_by "$no_clone"
	done
	for c in 'git commit -m "explain git clone"' 'echo git clone' 'bash -c "git clone x"' 'git status'; do
		guard_bash "$c"
		allowed
	done
}

@test "a rule for agents does nothing when ASSAY_AGENT is empty; one for everyone runs anyway" {
	cd "$T"
	example_rules
	for agent in unset ""; do
		if [ "$agent" = unset ]; then unset ASSAY_AGENT; else export ASSAY_AGENT=; fi
		guard_bash 'git clone x'
		allowed
		guard_edit "$T/a/prod.env"
		denied_by "Environment files hold secrets: do not write them."
	done
}

@test "an Edit, Write or NotebookEdit inside a main checkout is denied; in a linked worktree it is allowed" {
	checkouts
	cd "$T"
	example_rules main-checkout-edit
	export ASSAY_AGENT=claude-code
	for tool in Edit Write NotebookEdit; do
		guard_edit "$T/repo/README.md" "$T" "$tool"
		denied_by "The main checkout stays clean: edit files in a worktree of your own." "$T/repo/README.md"
		guard_edit "$T/worktree/README.md" "$T" "$tool"
		allowed
	done
	# A file that does not exist yet, in directories that do not either; a path relative to the cwd.
	guard_edit "$T/repo/new/dir/file.txt"
	denied_by "The main checkout stays clean"
	guard_edit "README.md" "$T/repo"
	denied_by "$T/repo/README.md"
	guard_edit "../repo/new.txt" "$T/worktree"
	denied_by "$T/repo/new.txt"
	for path in "$T/worktree/new/file.txt" "$T/notes.md" "$T/repo/../notes.md" "$T/origin.git/config"; do
		guard_edit "$path"
		allowed
	done
	# The main checkout's git dir sits in it, a linked worktree's private part included.
	guard_edit "$T/repo/.git/hooks/pre-commit"
	denied_by "$T/repo/.git/hooks/pre-commit is in the main checkout $T/repo"
	guard_edit "$T/repo/.git/worktrees/worktree/info/exclude"
	denied_by "is in the main checkout $T/repo"
}

# path_rule <glob>: RULES holds one path rule, for everyone, matching the glob.
path_rule() {
	RULES=$T/rules.json
	jq -n --arg g "$1" '{version: 1, rules: [{name: "glob", on: "path", match: $g, message: "matched", who: "everyone"}]}' \
		>"$RULES"
}

@test "a path rule's glob: a name, a whole path, or a path's end; * and ? within a component, ** across them" {
	cd "$T"
	# <glob> <path> <denied: 1 or 0>
	while read -r glob path denied; do
		path_rule "$glob"
		guard_edit "$path"
		echo "$glob $path: expected $denied"
		if [ "$denied" = 1 ]; then denied_by matched; else allowed; fi
	done <<'CASES'
*.env /a/b/prod.env 1
*.env /a/prod.env/x 0
*.env /a/env 0
/etc/** /etc/x/y 1
/etc/** /home/etc/x 0
.ssh/* /home/u/.ssh/id 1
.ssh/* /home/u/.ssh/a/id 0
.ssh/* /home/u/x.ssh/id 0
secrets/**/*.yaml /r/secrets/a/b.yaml 1
secrets/**/*.yaml /r/secrets/b.yaml 1
secrets/**/*.yaml /r/mysecrets/b.yaml 0
**/build/* /r/a/build/x 1
id_[!.]* /h/id_rsa 1
id_[!.]* /h/id_.pub 0
a?c /x/abc 1
a?c /x/a/c 0
file.txt /x/fileXtxt 0
a+(b) /x/a+(b) 1
a\*b /x/a*b 1
a\*b /x/axb 0
a[b /x/a[b 1
a[b /x/ab 0
CASES
}

@test "a command rule with a cwd runs only when the cwd matches it: main-checkout" {
	checkouts
	example_rules main-checkout-commit
	export ASSAY_AGENT=claude-code
	guard_bash 'git commit -m x' "$T/repo"
	denied_by "The main checkout stays on its default branch: commit in a worktree of your own."
	for cwd in "$T/worktree" "$T"; do
		guard_bash 'git commit -m x' "$cwd"
		allowed
	done
	# A repo without a remote is a main checkout too.
	guard_bash 'git commit -m x' "$T/local"
	denied_by "The main checkout stays on its default branch"
	guard_bash 'git pull' "$T/repo"
	allowed
}

@test "a command rule with fileContent reads the file the match binds to \$FILE; a match without one counts as is" {
	cd "$T"
	example_rules pr-attribution
	export ASSAY_AGENT=claude-code
	printf 'Fix.\n\nGenerated with a tool\n' >attributed.md
	printf 'Fix the parser.\n' >plain.md
	cp attributed.md 'with space.md'
	for c in 'gh pr create --title t --body-file attributed.md' 'gh pr edit 3 -F attributed.md' \
		'gh pr create --body-file "with space.md"' 'gh pr create --body-file=attributed.md' \
		"gh pr create --body-file '$T/attributed.md'" "gh pr create --body 'Fix.

Generated with a tool'" 'git add . && gh pr create -t x -F attributed.md'; do
		guard_bash "$c"
		denied_by "A pull request's description names no tool that wrote it."
	done
	for c in 'gh pr create --title t --body-file plain.md' 'gh pr create --body-file missing.md' \
		'gh pr create --body-file -' 'gh pr create --body "Fix the parser."' 'cat attributed.md'; do
		guard_bash "$c"
		allowed
	done
	# A file under the home directory, as the shell expands ~.
	cp attributed.md "$HOME/pr.md"
	guard_bash 'gh pr create --body-file ~/pr.md'
	denied_by "A pull request's description"
	# The file is read relative to the session's cwd.
	mkdir sub
	guard_bash 'gh pr create --body-file ../attributed.md' "$T/sub"
	denied_by "A pull request's description"
}

@test "Stop with uncommitted changes blocks once; nothing when stop_hook_active is true" {
	checkouts
	cd "$T"
	example_rules save-work
	export ASSAY_AGENT=claude-code
	save='Commit and push your branch before you stop, unfinished work included (wip: ...).'
	guard_stop "$T/worktree"
	allowed
	echo draft >"$T/worktree/draft.txt"
	guard_stop "$T/worktree"
	[ "$status" -eq 0 ]
	jq -e --arg m "$save" '.decision == "block" and (.reason | startswith($m)) and (.reason | contains("uncommitted"))' \
		<<<"$output"
	guard_stop "$T/worktree" true
	allowed
	# From a subdirectory too.
	mkdir "$T/worktree/sub"
	guard_stop "$T/worktree/sub"
	jq -e '.decision == "block"' <<<"$output"
}

@test "Stop with unpushed commits blocks, with a remote only; outside a repo nothing" {
	checkouts
	cd "$T"
	example_rules save-work
	export ASSAY_AGENT=claude-code
	git -C "$T/worktree" commit --quiet --allow-empty -m wip
	guard_stop "$T/worktree"
	jq -e '.decision == "block" and (.reason | contains("1 commit"))' <<<"$output"
	# A branch never pushed: its commits are on no remote.
	git -C "$T/worktree" switch --quiet -c agent/other
	git -C "$T/worktree" push --quiet origin agent/example
	guard_stop "$T/worktree"
	allowed
	git -C "$T/worktree" commit --quiet --allow-empty -m more
	guard_stop "$T/worktree"
	jq -e '.decision == "block"' <<<"$output"
	# No remote: commits have nowhere to go, uncommitted changes still block.
	git -C "$T/local" commit --quiet --allow-empty -m local
	guard_stop "$T/local"
	allowed
	echo x >"$T/local/x.txt"
	guard_stop "$T/local"
	jq -e '.decision == "block"' <<<"$output"
	guard_stop "$T"
	allowed
	unset ASSAY_AGENT
	guard_stop "$T/local"
	allowed
}

@test "a command rule's match may be a rule file's body: rule, constraints, utils, transform" {
	cd "$T"
	export ASSAY_AGENT=claude-code
	RULES=$T/rules.json
	jq -n '{version: 1, rules: [{name: "git-clone", on: "command", message: "no clone",
    match: {rule: {kind: "command", all: [{has: {field: "name", pattern: "$NAME"}}, {has: {kind: "word", regex: "^clone$"}}]},
      constraints: {NAME: {regex: "^(git|gh)$"}}}}]}' >"$RULES"
	guard_bash 'gh clone x'
	denied_by "no clone"
	guard_bash 'hg clone x'
	allowed
	# --rules=<file> is the same option.
	event=$(bash_event 'git clone x')
	run --separate-stderr "$assay" guard --rules="$RULES" <<<"$event"
	denied_by "no clone"
	jq '.rules[0].match.message = "x"' "$RULES" >"$T/bad.json"
	RULES=$T/bad.json
	guard_bash 'git clone x'
	echo "$stderr"
	[ "$status" -eq 1 ]
	[[ $stderr == *"rule git-clone: a match with a rule key is a rule file body"* ]]
}

@test "other events and tools pass" {
	cd "$T"
	example_rules
	export ASSAY_AGENT=claude-code
	guard '{"hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": {"file_path": "/a/prod.env"}}'
	allowed
	guard '{"hook_event_name": "UserPromptSubmit", "prompt": "git clone x"}'
	allowed
	guard '{"hook_event_name": "PreToolUse", "tool_name": "Bash"}'
	allowed
	guard '{"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": "git clone x"}'
	allowed
}

# fails_open <stderr text>: exit 1, nothing on stdout, the text on stderr.
fails_open() {
	echo "status $status, stdout: $output, stderr: $stderr"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[[ $stderr == *"$1"* ]]
}

@test "the guard fails open: exit 1, never 2, on its own error" {
	cd "$T"
	export ASSAY_AGENT=claude-code
	event=$(bash_event 'git clone x')
	RULES=$T/missing.json
	guard "$event"
	fails_open "assay: cannot read the rule list $T/missing.json"
	RULES=$T/rules.json
	echo '{"version": 1, "rules": [' >"$RULES"
	guard "$event"
	fails_open "assay: invalid rule list $RULES"
	for bad in '{"version": 2, "rules": []}' \
		'{"version": 1, "rules": [{"name": "a", "on": "file", "match": "x", "message": "m"}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "command", "match": "git clone", "message": "m"}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "path", "match": "*", "message": "two\nlines"}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "path", "match": "*", "message": "m", "who": "people"}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "path", "match": "*", "message": "m", "cwd": "*"}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "stop", "match": "dirty", "message": "m"}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "pre-push", "match": "main", "message": "m"}]}' \
		'{"version": 1, "rules": [{"name": "a b", "on": "path", "match": "*", "message": "m"}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "path", "match": "*", "message": "m"}, {"name": "a", "on": "path", "match": "x", "message": "m"}]}'; do
		printf '%s\n' "$bad" >"$RULES"
		guard "$event"
		fails_open "assay: invalid rule list $RULES: "
	done
	example_rules
	guard 'not json'
	fails_open "assay: invalid event"
	guard '["PreToolUse"]'
	fails_open "assay: invalid event"
	run --separate-stderr "$assay" guard <<<"$event"
	fails_open "guard needs --rules <file>"
	# A command rule ast-grep rejects, and no ast-grep at all.
	jq -n '{version: 1, rules: [{name: "a", on: "command", match: {kind: "no-such-kind"}, message: "m"}]}' >"$T/rules.json"
	RULES=$T/rules.json
	guard "$event"
	fails_open "assay: ast-grep cannot match the command rules"
	example_rules
	mkdir "$T/bin"
	for t in jq git realpath bash cat mktemp rm; do
		target=$(command -v "$t")
		ln -s "$target" "$T/bin/$t"
	done
	run --separate-stderr env PATH="$T/bin" "$assay" guard --rules "$RULES" <<<"$event"
	fails_open "assay: cannot find ast-grep on the PATH"
}
