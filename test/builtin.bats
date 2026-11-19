bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

# The built-in checks, as assay's devenv module configures them (test/defaults/*.json): their list, and the checks
# that run a tool, oxfmt and actionlint. The checks that are assay's own code have a test file each.

untimed() { sed -E 's/ [0-9]+\.[0-9]{2}s/ Ns/g' <<<"$output"; }

@test "assay check --list shows the built-in checks, all fast" {
	local_repo
	builtin_checks plain
	run --separate-stderr "$assay" check --list
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s (fast)\n' actionlint agents-md commit-trailers gitleaks oxfmt suppressions)" ]
}

@test "a repo in shape passes every built-in check; without workflows actionlint is skipped" {
	shaped_repo
	builtin_checks plain
	run --separate-stderr "$assay" check --base HEAD
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]%% in *}" = "6 checks passed" ]
	git rm --quiet -r .github
	git commit --quiet -m "no workflows"
	run --separate-stderr "$assay" check --base HEAD
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "  skipped: actionlint (no .github/workflows/*)" ]
}

@test "oxfmt, in a project that is not a JavaScript project: Markdown and YAML, not TOML or JSON" {
	shaped_repo
	builtin_checks plain
	printf '%s\n' '# Notes' '' '* one' '* two' >notes.md
	printf '%s\n' 'name = "x"' 'dependencies = [' '    "httpx",' ']' >pyproject.toml
	printf '%s\n' '{"a":1,' '"b":2}' >data.json
	printf '%s\n' 'const a = {b:1}' >tool.ts
	run --separate-stderr "$assay" check oxfmt
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *$'\n$ oxfmt --check --no-error-on-unmatched-pattern \'**/*.{md,mdx,yml,yaml}\'\n'* ]]
	[[ $output == *"notes.md"* ]]
	[[ $output != *"pyproject.toml"* && $output != *"data.json"* && $output != *"tool.ts"* ]]
	printf '%s\n' '# Notes' '' '- one' '- two' >notes.md
	printf '%s\n' 'a:   1' 'b:' '    - x' >config.yaml
	run --separate-stderr "$assay" check oxfmt
	[ "$status" -eq 1 ]
	[[ $output == *"config.yaml"* && $output != *"notes.md"* ]]
	printf '%s\n' 'a: 1' 'b:' '  - x' >config.yaml
	run --separate-stderr "$assay" check oxfmt
	[ "$status" -eq 0 ]
}

@test "oxfmt: the fix is the check's command without --check; nothing to check passes" {
	local_repo
	builtin_checks plain
	printf '%s\n' '# Notes' '' '* one' >notes.md
	run --separate-stderr "$assay" check oxfmt
	[ "$status" -eq 1 ]
	fix=$(jq -r '.checks.oxfmt.exec' "$ASSAY_CONFIG")
	bash -c "${fix/ --check/}" >/dev/null 2>&1
	[ "$(cat notes.md)" = "$(printf '%s\n' '# Notes' '' '- one')" ]
	run --separate-stderr "$assay" check oxfmt
	[ "$status" -eq 0 ]
	rm notes.md
	run --separate-stderr "$assay" check oxfmt
	[ "$status" -eq 0 ]
}

@test "oxfmt skips a file listed in the repo's .oxfmtrc.json ignorePatterns, and ignored files" {
	local_repo
	builtin_checks plain
	mkdir secrets .devenv
	printf '%s\n' 'key:' '    value: ENC[x]' >secrets/prod.yaml
	printf '%s\n' '* x' >.devenv/notes.md
	echo .devenv/ >.gitignore
	run --separate-stderr "$assay" check oxfmt
	[ "$status" -eq 1 ]
	[[ $output == *"secrets/prod.yaml"* && $output != *".devenv"* ]]
	echo '{ "ignorePatterns": ["secrets/*.yaml"] }' >.oxfmtrc.json
	run --separate-stderr "$assay" check oxfmt
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[0]} != *"loosening"* ]]
}

@test "oxfmt checks JSON and TypeScript only with languages.javascript, and only under its directory" {
	local_repo
	mkdir frontend backend
	printf '%s\n' '{"a":1,' '"b":2}' | tee frontend/package.json >backend/data.json
	printf '%s\n' 'const a = {b:1}' >frontend/a.ts
	builtin_checks javascript
	run --separate-stderr "$assay" check oxfmt
	[ "$status" -eq 1 ]
	[[ $output == *"backend/data.json"* && $output == *"frontend/package.json"* && $output == *"frontend/a.ts"* ]]
	builtin_checks javascript-frontend
	run --separate-stderr "$assay" check oxfmt
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output != *"backend/data.json"* && $output == *"frontend/package.json"* && $output == *"frontend/a.ts"* ]]
	# The fix formats the project's files and leaves the backend's JSON alone.
	fix=$(jq -r '.checks.oxfmt.exec' "$ASSAY_CONFIG")
	bash -c "${fix/ --check/}" >/dev/null 2>&1
	[ "$(cat backend/data.json)" = "$(printf '%s\n' '{"a":1,' '"b":2}')" ]
	run --separate-stderr "$assay" check oxfmt
	[ "$status" -eq 0 ]
}

@test "actionlint fails on a broken workflow, shellcheck over run: blocks included" {
	shaped_repo
	builtin_checks plain
	# shellcheck disable=SC2016 # the workflow's own $FOO
	printf '%s\n' '  other:' '    needs: missing' '    runs-on: ubuntu-latest' '    steps:' '      - run: echo $FOO' \
		>>.github/workflows/check.yml
	run --separate-stderr "$assay" check actionlint
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *'job "other" needs job "missing" which does not exist'* ]]
	[[ $output == *"SC2086"* ]]
}
