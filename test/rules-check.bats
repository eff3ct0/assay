bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# nix/rules-check.sh, which the flake's check builder (lib.rulesCheck) runs: every example of a rendered rule list fed
# to the real entrypoints, each with its rule alone, in a fresh fixture. It fails when a deny example passes or an
# allow example is denied.

rules_check=$BATS_TEST_DIRNAME/../nix/rules-check.sh

# check_rules <rules file>: run the check with this checkout's assay on the PATH.
check_rules() {
	PATH=$DEVENV_STUB_PROFILE:$PATH run --separate-stderr bash "$rules_check" "$1"
	echo "status $status"
	echo "stdout: $output"
	echo "stderr: $stderr"
}
# edited <jq filter>: a copy of the example list changed by the filter, in $T/rules.json.
edited() {
	jq "$1" "$BATS_TEST_DIRNAME/rules/example.json" >"$T/rules.json"
}

@test "over the example list, every deny example is denied and every allow example passes" {
	cd "$T"
	check_rules "$BATS_TEST_DIRNAME/rules/example.json"
	[ "$status" -eq 0 ]
	[ -z "$stderr" ]
	# One line per example, in the list's order.
	oks=$(grep -c '^ok ' <<<"$output")
	examples=$(jq '[.rules[] | (.deny + .allow)[]] | length' "$BATS_TEST_DIRNAME/rules/example.json")
	[ "$oks" -eq "$examples" ]
	[[ $output == *'ok   no-clone deny 1: cd x && git clone y'* ]]
	[[ $output == *'ok   save-work allow 2: {"unpushed":true,"remote":false}'* ]]
	last=$(tail -n 1 <<<"$output")
	[ "$last" = "rules check: 9 rules, 29 examples, all as expected" ]
}

@test "workspaceRoot scopes both path and command examples to physical main checkouts" {
	cd "$T"
	# shellcheck disable=SC2016 # $on is a jq binding.
	edited '.rules |= map(select(.name | startswith("main-checkout-"))
      | .workspaceRoot = "/deployment/workspace"
      | .on as $on
      | def events: map(if $on == "path" then {path: (. + "/new/file.md")}
                        else {command: "git commit -m x", cwd: .} end);
      .deny = (["workspace/repo", "alias"] | events)
      | .allow = (["outside", "workspace-other", "workspace/worktree"] | events))'
	check_rules "$T/rules.json"
	[ "$status" -eq 0 ]
	[[ $output == *'2 rules, 10 examples, all as expected'* ]]
}

@test "an allow example that is denied fails the check, naming the rule, the example and the reason" {
	cd "$T"
	edited '(.rules[] | select(.name == "no-clone") | .allow) += [{command: "git clone z"}]'
	check_rules "$T/rules.json"
	[ "$status" -eq 1 ]
	[[ $output == *'FAIL no-clone allow 3: git clone z: denied: Get repos and worktrees through the workspace tool'* ]]
	last=$(tail -n 1 <<<"$output")
	[ "$last" = "rules check: 9 rules, 30 examples, 1 not as expected" ]
}

@test "a deny example that passes fails the check, for each kind of rule" {
	cd "$T"
	edited '
    (.rules[] | select(.name == "no-coauthor") | .deny) += [{message: "Fix\n"}]
    | (.rules[] | select(.name == "main-checkout-edit") | .deny) += [{path: "worktree/x.md"}]
    | (.rules[] | select(.name == "main-checkout-commit") | .deny) += [{command: "git commit -m x", cwd: "worktree"}]
    | (.rules[] | select(.name == "pr-attribution") | .deny) += [{command: "gh pr create --body-file b.md", files: {"b.md": "Fix\n"}}]
    | (.rules[] | select(.name == "agent-branch") | .deny) += [{ref: "refs/heads/agent/y"}]
    | (.rules[] | select(.name == "agents-md-shape") | .deny) += [{files: {"CLAUDE.md": "@AGENTS.md\n"}}]
    | (.rules[] | select(.name == "save-work") | .deny) += [{unpushed: true, remote: false}]'
	check_rules "$T/rules.json"
	[ "$status" -eq 1 ]
	[[ $output == *'FAIL no-coauthor deny 2: Fix\n: passes'* ]]
	[[ $output == *'FAIL main-checkout-edit deny 2: worktree/x.md: passes'* ]]
	[[ $output == *'FAIL main-checkout-commit deny 2: git commit -m x (in worktree): passes'* ]]
	[[ $output == *'FAIL pr-attribution deny 3: gh pr create --body-file b.md: passes'* ]]
	[[ $output == *'FAIL agent-branch deny 2: refs/heads/agent/y: passes'* ]]
	[[ $output == *'FAIL agents-md-shape deny 2: {"files":{"CLAUDE.md":"@AGENTS.md\n"}}: passes'* ]]
	[[ $output == *'FAIL save-work deny 3: {"unpushed":true,"remote":false}: passes'* ]]
	last=$(tail -n 1 <<<"$output")
	[ "$last" = "rules check: 9 rules, 36 examples, 7 not as expected" ]
}

@test "a pre-push example's files land over a tree with the shape, and null removes one" {
	cd "$T"
	edited '.rules |= map(select(.name == "agents-md-shape")) | .rules[0].deny = [{files: {"CLAUDE.md": null}}]
    | .rules[0].allow = [{}, {ref: "refs/heads/main"}, {files: {"src/main.rs": "fn main() {}\n"}}]'
	check_rules "$T/rules.json"
	[ "$status" -eq 0 ]
}

@test "agents' rules run with ASSAY_AGENT set, everyone's without it" {
	cd "$T"
	mkdir "$T/bin"
	# The shebang names bash itself: the sandbox of nix flake check has no /usr/bin/env.
	# shellcheck disable=SC2016 # the stub's own $ASSAY_AGENT, $2 and $4
	printf '#!%s\necho "${ASSAY_AGENT-unset} $2 $4" >>"%s"\nexec "%s" "$@"\n' "$BASH" "$T/agents.log" "$assay" \
		>"$T/bin/assay"
	chmod +x "$T/bin/assay"
	edited '.rules |= map(select(.name == "no-coauthor" or .name == "no-clone"))'
	PATH=$T/bin:$PATH run bash "$rules_check" "$T/rules.json"
	[ "$status" -eq 0 ]
	cat "$T/agents.log"
	n=$(grep -c '^unset .*commit-msg$' "$T/agents.log")
	[ "$n" -eq 3 ]
	n=$(grep -c '^assay-rules-check ' "$T/agents.log")
	[ "$n" -eq 4 ]
	n=$(wc -l <"$T/agents.log")
	[ "$n" -eq 7 ]
}

@test "a list it cannot use fails the check before any example runs" {
	cd "$T"
	for bad in '{"version": 1, "rules": [{"name": "a", "on": "commit-msg", "match": "x", "message": "m", "allow": [{"message": "y"}]}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "commit-msg", "match": "x", "message": "m", "deny": [], "allow": [{"message": "y"}]}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "commit-msg", "match": "x", "message": "m", "deny": [{"command": "x"}], "allow": [{"message": "y"}]}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "stop", "match": "unsaved-work", "message": "m", "deny": [{"uncommitted": "yes"}], "allow": [{}]}]}' \
		'{"version": 1, "rules": [{"name": "a", "on": "path", "match": "*", "message": "m", "deny": ["x"], "allow": [{"path": "y"}]}]}' \
		'{"version": 2, "rules": []}' 'nope'; do
		printf '%s\n' "$bad" >"$T/rules.json"
		check_rules "$T/rules.json"
		[ "$status" -eq 1 ]
		[[ $stderr == "rules check: $T/rules.json: "* ]]
		[ -z "$output" ]
	done
	check_rules "$T/missing.json"
	[ "$status" -eq 1 ]
	[[ $stderr == "rules check: cannot read $T/missing.json"* ]]
}

@test "an entrypoint that fails on an example fails the check, with its error" {
	cd "$T"
	jq -n '{version: 1, rules: [{name: "a", on: "command", match: {kind: "no-such-kind"}, message: "m",
    deny: [{command: "git clone x"}], allow: [{command: "ls"}]}]}' >"$T/rules.json"
	check_rules "$T/rules.json"
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL a deny 1: git clone x: assay guard exited 1: assay: ast-grep cannot match the command rules"* ]]
	jq -n '{version: 1, rules: [{name: "a", on: "commit-msg", match: "(", message: "m", who: "everyone",
    deny: [{message: "x"}], allow: [{message: "y"}]}]}' >"$T/rules.json"
	check_rules "$T/rules.json"
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL a allow 1: y: assay git-hook exited 1: assay: cannot evaluate rules: rule a's regex cannot be used"* ]]
}
