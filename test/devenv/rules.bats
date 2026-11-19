# shellcheck disable=SC2016 # the fixtures' scripts are literal text
bats_require_minimum_version 1.5.0
# shellcheck source=test/devenv/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

# Code rules in a real devenv: the ast-grep check, a rule pack the repo turns on, and assay rule new.

@test "a repo that turns on a rule pack gets its rules in the ast-grep check, with ast-grep in its devenv" {
	consumer "$ASSAY_WITH_PACK"
	devenv_nix '{ assay.rulePacks = [ "nope" ]; }'
	run devenv shell -- true
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"assay.rulePacks names no rule pack assay ships: nope (it ships demo)"* ]]
	devenv_nix '{ assay.rulePacks = [ "demo" ]; }'
	printf '%s\n' 'if which git >/dev/null; then echo yes; fi' >tool.sh
	run --separate-stderr devenv shell -- assay check ast-grep
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *"error[demo-no-which]: Find a command with \`command -v\`, not \`which\`."* ]]
	# Without sgconfig.yml: the pack is an opt-in of its own. Its fix, through the devenv's ast-grep.
	[ ! -e sgconfig.yml ]
	fix=$(grep -o 'ast-grep scan -c [^`]* -U' <<<"$output")
	devenv shell -- bash -c "$fix" >/dev/null
	[ "$(cat tool.sh)" = 'if command -v git >/dev/null; then echo yes; fi' ]
	run --separate-stderr devenv shell -- assay check ast-grep
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "assay rule new in a real devenv: the repo's one language, placeholders that fail the check, a rule that holds" {
	consumer
	devenv_nix '{ languages.shell.enable = true; }'
	printf '%s\n' '#!/usr/bin/env bash' 'eval "$1"' >run.sh
	run --separate-stderr devenv shell -- assay rule new no-eval
	echo "$stderr"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' sgconfig.yml rules/no-eval.yml rule-tests/no-eval-test.yml)" ]
	[ "$(yq '.language' rules/no-eval.yml)" = bash ]
	run --separate-stderr devenv shell -- assay check ast-grep
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *"placeholders of assay rule new left in the rules and their tests"* ]]
	# From outside the devenv, through it, the language from --from's file.
	run --separate-stderr "$ASSAY/assay.sh" rule new no-eval-either --from run.sh:2
	echo "$stderr"
	[ "$status" -eq 0 ]
	[ "$(yq -o=json '.invalid[0]' rule-tests/no-eval-either-test.yml)" = '"eval \"$1\"\n"' ]
	rm rules/no-eval-either.yml rule-tests/no-eval-either-test.yml
	# Filled in.
	cat >rules/no-eval.yml <<'RULE'
id: no-eval
language: bash
severity: error
message: Call the command by name, not through eval.
note: |
  Why: eval runs whatever its string holds.
  Fix: call the command by name, with its arguments in an array.
  Not a fix: `bash -c`, or eval in a function of another name.
  If the rule is wrong here, stop and tell the user; exceptions go in the rule's own file.
rule:
  kind: command
  has:
    field: name
    regex: ^eval$
RULE
	printf '%s\n' 'id: no-eval' 'invalid:' '  - eval "$cmd"' 'valid:' '  - '"'"'"$@"'"'" '  - echo eval' \
		>rule-tests/no-eval-test.yml
	run --separate-stderr devenv shell -- assay check ast-grep oxfmt
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *"error[no-eval]"* && $output == *"run.sh:2:1"* ]]
	printf '%s\n' '#!/usr/bin/env bash' '"$@"' >run.sh
	run --separate-stderr devenv shell -- assay check ast-grep oxfmt
	echo "$output"
	[ "$status" -eq 0 ]
}
