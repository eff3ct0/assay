# shellcheck disable=SC2016 # the fixtures' scripts and rules, and the messages' backquotes, are literal text
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

# ast-grep: the repo's ast-grep rules (sgconfig.yml at the root) and the rule packs it turns on, in three steps, each
# run only when the one before passed: a plain text search, `ast-grep test --skip-snapshot-tests`, `ast-grep scan`.

@test "without sgconfig.yml, the ast-grep check is skipped and listed" {
	local_repo
	builtin_checks plain
	run --separate-stderr "$assay" check --base HEAD ast-grep
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "  skipped: ast-grep (no sgconfig.yml)" ]
	[ "${lines[2]}" = "skip ast-grep (no sgconfig.yml)" ]
}

@test "the repo's rules: a tree they hold passes; a finding fails, with the rule's message and note" {
	local_repo
	builtin_checks plain
	sg_project
	run --separate-stderr "$assay" check --base HEAD ast-grep
	echo "$output"
	[ "$status" -eq 0 ]
	printf '%s\n' 'cmd="ls -l"' 'eval "$cmd"' >>script.sh
	run --separate-stderr "$assay" builtin ast-grep
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *'$ ast-grep test --skip-snapshot-tests --color never'*'$ ast-grep scan --color never'* ]]
	[[ $output == *"error[no-eval]: Call the command by name, not through eval."* ]]
	[[ $output == *"script.sh:3:1"* ]]
	[[ $output == *"Why: eval runs whatever its string holds."* ]]
	[ "${lines[-1]}" = "ast-grep scan found code a rule forbids: fix each finding; \`ast-grep scan -U\` applies a rule's fix:, where it has one." ]
}

@test "ast-grep-ignore outside the rule directories fails, in any file git sees, before ast-grep runs" {
	local_repo
	builtin_checks plain
	sg_project
	echo '.devenv/' >.gitignore
	mkdir -p src .devenv
	printf '%s\n' 'echo a' 'eval "$x" # ast-grep-ignore' >src/tracked.sh
	git add -A
	git commit --quiet -m tracked
	printf '%s\n' '# ast-grep-ignore: no-eval' 'eval "$y"' >untracked.sh
	echo '<!-- ast-grep-ignore -->' >notes.md
	echo '# ast-grep-ignore' >.devenv/ignored.sh
	echo '# ast-grep-ignore in the rule directories is the rule'"'"'s own' >>rules/no-eval.yml
	run --separate-stderr "$assay" builtin ast-grep
	echo "$output"
	[ "$status" -eq 1 ]
	expected="notes.md:1:<!-- ast-grep-ignore -->
src/tracked.sh:2:eval \"\$x\" # ast-grep-ignore
untracked.sh:1:# ast-grep-ignore: no-eval
3 lines with ast-grep-ignore outside the rule directories: remove each one. An exception lives in the rule's own file (its ignores, or a not: clause in its rule), where a review sees it; an ast-grep-ignore also silences a rule written to forbid it."
	[ "$output" = "$expected" ]
	rm untracked.sh notes.md
	git rm --quiet src/tracked.sh
	run --separate-stderr "$assay" builtin ast-grep
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a rule whose tests fail fails the check, and the scan does not run" {
	local_repo
	sg_project
	# A valid case the rule reports.
	printf '%s\n' '  - eval "$cmd"' >>rule-tests/no-eval-test.yml
	printf '%s\n' 'eval "$x"' >>script.sh
	run --separate-stderr "$assay" builtin ast-grep
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *'$ ast-grep test --skip-snapshot-tests --color never'* ]]
	[[ $output == *"FAIL no-eval"* ]]
	[[ $output != *'$ ast-grep scan'* ]]
	[ "${lines[-1]}" = "ast-grep test failed: each rule reports its invalid cases and none of its valid ones; fix the rule or its tests." ]
}

@test "an existing sgconfig.yml is respected, whatever directories it names" {
	local_repo
	sg_project
	mkdir -p lint
	mv rules lint/checks
	mv rule-tests lint/cases
	printf '%s\n' 'ruleDirs: [lint/checks]' 'testConfigs:' '  - testDir: "lint/cases"' >sgconfig.yml
	echo '# ast-grep-ignore is the rule'"'"'s own here' >>lint/checks/no-eval.yml
	echo '# ast-grep-ignore is the rule'"'"'s own here' >>lint/cases/no-eval-test.yml
	run --separate-stderr "$assay" builtin ast-grep
	echo "$output"
	[ "$status" -eq 0 ]
	echo '# ast-grep-ignore' >rules.sh
	printf '%s\n' 'eval "$x"' >>script.sh
	run --separate-stderr "$assay" builtin ast-grep
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "rules.sh:1:# ast-grep-ignore" ]
	rm rules.sh
	run --separate-stderr "$assay" builtin ast-grep
	[ "$status" -eq 1 ]
	[[ $output == *"error[no-eval]"* ]]
}

@test "a placeholder of assay rule new left in the rule directories fails the check" {
	local_repo
	sg_project
	sed -i 's/^message: .*/message: "<fill in: what is wrong and what to do instead>"/' rules/no-eval.yml
	printf '%s\n' '  - "<fill in: a near miss>"' >>rule-tests/no-eval-test.yml
	run --separate-stderr "$assay" builtin ast-grep
	echo "$output"
	[ "$status" -eq 1 ]
	expected='rule-tests/no-eval-test.yml:7:  - "<fill in: a near miss>"
rules/no-eval.yml:4:message: "<fill in: what is wrong and what to do instead>"
2 placeholders of assay rule new left in the rules and their tests: fill each one in, as the comment above its field says.'
	[ "$output" = "$expected" ]
}

@test "an sgconfig.yml that is not YAML fails the check" {
	local_repo
	printf '%s\n' 'ruleDirs: [' >sgconfig.yml
	run --separate-stderr "$assay" builtin ast-grep
	echo "$output"
	[ "$status" -eq 1 ]
	[[ ${lines[0]} == "sgconfig.yml cannot be read as YAML: "* ]]
}

@test "a rule pack the repo turns on runs its tests and its rules over the repo, with or without sgconfig.yml" {
	local_repo
	builtin_checks plain
	rule_packs demo
	pack=$BATS_TEST_DIRNAME/packs/demo
	printf '%s\n' 'if which git >/dev/null; then echo yes; fi' >tool.sh
	run --separate-stderr "$assay" builtin ast-grep
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *"\$ ast-grep test -c $pack/sgconfig.yml --skip-snapshot-tests --color never"*"PASS demo-no-which"* ]]
	[[ $output == *"\$ ast-grep scan -c $pack/sgconfig.yml --color never"*"error[demo-no-which]: Find a command with \`command -v\`, not \`which\`."* ]]
	[[ $output == *$'\ntool.sh\nerror[demo-no-which]'* ]]
	[ "${lines[-1]}" = "ast-grep scan found code a rule forbids: fix each finding; \`ast-grep scan -c $pack/sgconfig.yml -U\` applies a pack rule's fix:, where it has one." ]
	# The pack's fix, as the last line gives it.
	ast-grep scan -c "$pack/sgconfig.yml" -U >/dev/null
	[ "$(cat tool.sh)" = 'if command -v git >/dev/null; then echo yes; fi' ]
	# The repo's own rules and the pack's, together.
	sg_project
	printf '%s\n' 'which ls' 'eval "$x"' >>script.sh
	run --separate-stderr "$assay" builtin ast-grep
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *"error[no-eval]"*"error[demo-no-which]"* ]]
}

@test "without ast-grep on the PATH, assay builtin ast-grep exits 127" {
	local_repo
	sg_project
	mkdir "$T/bin"
	for t in git jq yq awk mktemp rm cat realpath dirname; do
		if command -v "$t" >/dev/null; then ln -s "$(command -v "$t")" "$T/bin/$t"; fi
	done
	run -127 --separate-stderr env PATH="$T/bin" "$BASH" "$assay" builtin ast-grep
	[ "$status" -eq 127 ]
	[ "$stderr" = "assay: cannot find ast-grep on the PATH" ]
}

@test "nothing to check passes: no sgconfig.yml and no rule pack" {
	local_repo
	run --separate-stderr "$assay" builtin ast-grep
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
