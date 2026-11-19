# shellcheck disable=SC2030,SC2031 # bats runs each test in a process of its own: what one test sets, no other reads
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

# assay git-hook: the global git hooks, commit-msg and pre-push, registered as config-based hooks (git 2.54). A violated
# rule exits 1 with its message; a hook that cannot evaluate its rules exits 1 too (it fails closed). The rules come
# from test/rules/example.json.

coauthor='A commit names no co-author: remove the Co-Authored-By trailer.'
agent_branch='Agent branches start with agent/: push your work as agent/<topic>.'
shape='Every repo has AGENTS.md with the instructions and CLAUDE.md as the single line @AGENTS.md.'
zero=0000000000000000000000000000000000000000

# commit_msg <message>: run the commit-msg hook over a message file holding it.
commit_msg() {
	printf '%s' "$1" >"$T/COMMIT_EDITMSG"
	run --separate-stderr "$assay" git-hook --rules "$RULES" commit-msg "$T/COMMIT_EDITMSG"
}
# pre_push <stdin line>... : run the pre-push hook as git would for a push to origin, from the cwd.
pre_push() {
	local lines
	lines=$(printf '%s\n' "$@")
	run --separate-stderr "$assay" git-hook --rules "$RULES" pre-push origin "$T/origin.git" <<<"$lines"
}
# rejected <text>...: exit 1, each text on stderr, nothing on stdout.
rejected() {
	echo "status $status, stdout: $output, stderr: $stderr"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	local m
	for m in "$@"; do [[ $stderr == *"$m"* ]]; done
}
accepted() {
	echo "status $status, stdout: $output, stderr: $stderr"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ -z "$stderr" ]
}
# global_hooks: the config-based hooks assay's home-manager module registers, in the global git config.
global_hooks() {
	local hook
	for hook in commit-msg pre-push; do
		git config --global "hook.assay-$hook.event" "$hook"
		git config --global "hook.assay-$hook.command" "$assay git-hook --rules $RULES $hook"
	done
}

@test "commit-msg rejects a message a rule's regex matches, with the rule's name and message" {
	cd "$T"
	example_rules
	commit_msg $'Fix the parser\n\nCo-Authored-By: A <a@example.com>\n'
	rejected "assay: no-coauthor: $coauthor"
	commit_msg $'Fix the parser\n\nco-authored-by: A <a@example.com>'
	rejected "$coauthor"
	commit_msg $'Fix the parser\n\nReviewed-by: A <a@example.com>\n'
	accepted
	commit_msg $'Fix the co-authored-by: parser\n'
	accepted
}

@test "commit-msg reads the message as git stores it: no comments, nothing after the scissors line" {
	cd "$T"
	example_rules
	commit_msg $'Fix the parser\n\n# Co-Authored-By: A <a@example.com>\n'
	accepted
	commit_msg $'Fix the parser\n# ------------------------ >8 ------------------------\n+Co-Authored-By: A\n'
	accepted
}

@test "through git: a global config-based hook rejects the commit, and the repo's own commit-msg hook still runs" {
	local_repo
	example_rules
	global_hooks
	printf '#!/bin/sh\necho ran >>"%s"\n' "$T/own-hook.log" >.git/hooks/commit-msg
	chmod +x .git/hooks/commit-msg
	run --separate-stderr git commit --allow-empty -m $'Fix\n\nCo-Authored-By: A <a@example.com>'
	echo "status $status, stderr: $stderr"
	[ "$status" -ne 0 ]
	[[ $stderr == *"$coauthor"* ]]
	[ "$(git rev-list --count HEAD)" -eq 1 ]
	[ "$(wc -l <"$T/own-hook.log")" -eq 1 ]
	run --separate-stderr git commit --allow-empty -m Fix
	[ "$status" -eq 0 ]
	[ "$(git rev-list --count HEAD)" -eq 2 ]
	[ "$(wc -l <"$T/own-hook.log")" -eq 2 ]
}

@test "a rule for agents runs only with ASSAY_AGENT set; a hook with no rules accepts anything" {
	cd "$T"
	RULES=$T/rules.json
	jq -n '{version: 1, rules: [{name: "no-wip", on: "commit-msg", match: "^wip", message: "No wip commits here."}]}' >"$RULES"
	commit_msg 'wip: half'
	accepted
	ASSAY_AGENT='' commit_msg 'wip: half'
	accepted
	ASSAY_AGENT=claude-code commit_msg 'wip: half'
	rejected "No wip commits here."
	echo '{"version": 1, "rules": []}' >"$RULES"
	ASSAY_AGENT=claude-code commit_msg $'Fix\n\nCo-Authored-By: A'
	accepted
	checkouts
	cd "$T/worktree"
	ASSAY_AGENT=claude-code pre_push "refs/heads/x $(sha HEAD) refs/heads/feature $zero"
	accepted
}

@test "pre-push, in an agent session, rejects a branch that is neither agent/* nor the remote's default; tags pass" {
	checkouts
	cd "$T/worktree"
	example_rules agent-branch
	export ASSAY_AGENT=claude-code
	head=$(sha HEAD)
	pre_push "refs/heads/agent/example $head refs/heads/feature $zero"
	rejected "assay: agent-branch: $agent_branch" "refs/heads/feature"
	# A deletion is a push to that ref too.
	pre_push "(delete) $zero refs/heads/feature $head"
	rejected "$agent_branch"
	pre_push "refs/heads/agent/example $head refs/heads/agent/x $zero" "refs/heads/agent/example $head refs/heads/main $head" \
		"refs/tags/v1 $head refs/tags/v1 $zero" "refs/heads/agent/example $head refs/agent/notes $zero"
	accepted
	pre_push "refs/heads/agent/example $head refs/heads/agent/x $zero" "refs/heads/agent/example $head refs/heads/b $zero"
	rejected "refs/heads/b"
	[[ $stderr != *"refs/heads/agent/x"* ]]
	unset ASSAY_AGENT
	pre_push "refs/heads/agent/example $head refs/heads/feature $zero"
	accepted
}

@test "pre-push finds the remote's default branch without origin/HEAD, and an empty remote takes any first branch" {
	checkouts
	cd "$T/worktree"
	example_rules agent-branch
	export ASSAY_AGENT=claude-code
	head=$(sha HEAD)
	git remote set-head origin -d
	pre_push "refs/heads/agent/example $head refs/heads/main $head"
	accepted
	pre_push "refs/heads/agent/example $head refs/heads/feature $zero"
	rejected "$agent_branch"
	# A push to a URL, not to a named remote.
	run --separate-stderr "$assay" git-hook --rules "$RULES" pre-push "$T/origin.git" "$T/origin.git" \
		<<<"refs/heads/agent/example $head refs/heads/main $head"
	accepted
	git init --quiet --bare "$T/empty.git"
	run --separate-stderr "$assay" git-hook --rules "$RULES" pre-push "$T/empty.git" "$T/empty.git" \
		<<<"refs/heads/agent/example $head refs/heads/trunk $zero"
	accepted
	# A remote it cannot read: no default branch to compare with.
	run --separate-stderr "$assay" git-hook --rules "$RULES" pre-push gone "$T/gone.git" \
		<<<"refs/heads/agent/example $head refs/heads/feature $zero"
	rejected "assay: cannot evaluate rules: cannot find the default branch of gone"
}

# tip <claude-md content>: a commit on top of HEAD, not checked out, whose CLAUDE.md holds the content.
tip() {
	local tree
	tree=$( (
		git ls-tree HEAD | grep -v $'\tCLAUDE.md$' || true
		printf '100644 blob %s\tCLAUDE.md\n' \
			"$(printf '%s' "$1" | git hash-object -w --stdin)"
	) | git mktree)
	git commit-tree "$tree" -p HEAD -m tip
}

@test "pre-push rejects a tip whose CLAUDE.md copies AGENTS.md, in every repo; a tip with the shape passes" {
	checkouts
	cd "$T/worktree"
	example_rules agents-md-shape
	export ASSAY_AGENT=claude-code
	printf '# repo\n\n## Related repos\n\nNone.\n' >AGENTS.md
	echo '@AGENTS.md' >CLAUDE.md
	git add AGENTS.md CLAUDE.md
	git commit --quiet -m shape
	good=$(sha HEAD)
	copy=$(tip "$(cat AGENTS.md)"$'\n')
	pre_push "refs/heads/agent/example $copy refs/heads/agent/example $good"
	rejected "assay: agents-md-shape: $shape" \
		"refs/heads/agent/example: CLAUDE.md copies AGENTS.md: a copy falls short, even an identical one"
	pre_push "refs/heads/agent/example $good refs/heads/agent/example $zero" "(delete) $zero refs/heads/agent/old $copy"
	accepted
	# The tip's tree is read, not the working tree; tags are not branch tips.
	pre_push "refs/tags/v1 $copy refs/tags/v1 $zero"
	accepted
	pre_push "refs/heads/README $(sha HEAD~1) refs/heads/agent/x $zero"
	rejected "refs/heads/agent/x: AGENTS.md is missing"
}

@test "through git: the global pre-push hook rejects the push, and nothing reaches the remote" {
	checkouts
	cd "$T/worktree"
	example_rules
	global_hooks
	export ASSAY_AGENT=claude-code
	printf '# repo\n\n## Related repos\n\nNone.\n' >AGENTS.md
	echo '@AGENTS.md' >CLAUDE.md
	git add AGENTS.md CLAUDE.md
	git commit --quiet -m shape
	run --separate-stderr git push origin HEAD:refs/heads/feature
	[ "$status" -ne 0 ]
	[[ $stderr == *"$agent_branch"* ]]
	[ -z "$(git ls-remote "$T/origin.git" refs/heads/feature)" ]
	run --separate-stderr git push origin HEAD
	echo "$stderr"
	[ "$status" -eq 0 ]
}

@test "git-hook fails closed: exit 1 with 'assay: cannot evaluate rules:' when it cannot read or use its rules" {
	cd "$T"
	RULES=$T/missing.json
	commit_msg 'Fix'
	rejected "assay: cannot evaluate rules: cannot read the rule list $T/missing.json"
	RULES=$T/rules.json
	echo '{"version": 1, "rules": [{"name": "a", "on": "commit-msg", "message": "m"}]}' >"$RULES"
	commit_msg 'Fix'
	rejected "assay: cannot evaluate rules: invalid rule list $RULES: rule a: match must be a non-empty string"
	jq -n '{version: 1, rules: [{name: "a", on: "commit-msg", match: "(", message: "m", who: "everyone"}]}' >"$RULES"
	commit_msg 'Fix'
	rejected "assay: cannot evaluate rules: rule a's regex cannot be used"
	example_rules
	run --separate-stderr "$assay" git-hook --rules "$RULES" commit-msg "$T/no-such-file"
	rejected "assay: cannot evaluate rules: cannot read the message $T/no-such-file"
	run --separate-stderr "$assay" git-hook --rules "$RULES" pre-commit
	rejected "assay: cannot evaluate rules: no hook named 'pre-commit' (commit-msg or pre-push)"
	run --separate-stderr "$assay" git-hook --rules "$RULES"
	[ "$status" -eq 1 ]
	[[ $stderr == "assay: cannot evaluate rules: git-hook needs the hook's name"* ]]
	run --separate-stderr "$assay" git-hook commit-msg "$T/COMMIT_EDITMSG"
	[ "$status" -eq 1 ]
	[[ $stderr == "assay: cannot evaluate rules: git-hook needs --rules <file>"* ]]
}
