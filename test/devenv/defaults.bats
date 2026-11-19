# shellcheck disable=SC2016 # the fixtures' shell and Nix text is literal
bats_require_minimum_version 1.5.0
# shellcheck source=test/devenv/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# Nix's and bash's default checks, through the real devenv: a fixture project per language, each check failing on a
# defect and passing on its fix, and the coverage of new code of bash's test check. The consumers import a copy of
# assay with the languages' default checks alone, so that the built-in ones stay out of the way.

# check_fails <check> <text>: `assay check <check>` fails, and its output holds the text.
check_fails() {
	run --separate-stderr devenv shell -- assay check "$1"
	echo "$output"
	[ "$status" -eq 1 ]
	[[ ${lines[1]} == "FAIL $1 "* ]]
	[[ $output == *"$2"* ]]
}

# check_passes <check>...: `assay check <check>...` passes.
check_passes() {
	run --separate-stderr devenv shell -- assay check "$@"
	echo "$output"
	[ "$status" -eq 0 ]
}

# nix_fixture: Nix files every Nix check passes on.
nix_fixture() {
	mkdir -p lib
	printf '%s\n' '{ pkgs }:' '{' '  inherit pkgs;' '  answer = import ./lib/answer.nix;' '}' >default.nix
	printf '%s\n' '42' >lib/answer.nix
}

@test "Nix: assay check --list shows nixfmt, statix, deadnix and nixf-tidy as fast, nix flake check as full" {
	consumer "$ASSAY_LANGUAGES"
	devenv_nix '{ languages.nix.enable = true; }'
	run --separate-stderr devenv shell -- assay check --list
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' 'deadnix (fast)' nix-flake-check 'nixf-tidy (fast)' 'nixfmt (fast)' 'statix (fast)')" ]
}

@test "Nix: each check fails on its defect and passes on its fix; .devenv/ is never read; no flake.nix, no flake check" {
	consumer "$ASSAY_LANGUAGES"
	devenv_nix '{ languages.nix.enable = true; }'
	nix_fixture
	# Every defect at once, where only an ignored directory holds it.
	mkdir -p .devenv
	printf '%s\n' 'let unused = 1; in { pkgs }: { pkgs=pkgs; x = undefinedThing; }' >.devenv/defects.nix
	run --separate-stderr devenv shell -- assay check
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *"skip nix-flake-check (no flake.nix)"* ]]

	printf '%s\n' '{ a=1;}' >lib/format.nix
	check_fails nixfmt "lib/format.nix: not formatted"
	printf '%s\n' '{ a = 1; }' >lib/format.nix
	check_passes nixfmt

	printf '%s\n' '{ pkgs }:' '{' '  pkgs = pkgs;' '}' >lib/inherit.nix
	check_fails statix "lib/inherit.nix>3:3:W:3:This assignment is better written with \`inherit\`"
	printf '%s\n' '{ pkgs }:' '{' '  inherit pkgs;' '}' >lib/inherit.nix
	check_passes statix

	printf '%s\n' 'let' '  unused = 1;' 'in' '{ }' >lib/dead.nix
	check_fails deadnix "Unused let binding: unused"
	printf '%s\n' '{ }' >lib/dead.nix
	check_passes deadnix

	printf '%s\n' '{' '  x = undefinedThing;' '}' >lib/undefined.nix
	check_fails nixf-tidy 'lib/undefined.nix:2:7: error sema-undefined-variable: undefined variable `undefinedThing`'
	printf '%s\n' '{' '  x = 1;' '}' >lib/undefined.nix
	check_passes nixf-tidy

	check_passes
}

@test "Nix: nix flake check runs once flake.nix exists, and fails with the flake" {
	consumer "$ASSAY_LANGUAGES"
	devenv_nix '{ languages.nix.enable = true; }'
	printf '%s\n' '{' '  outputs = _: throw "a broken flake";' '}' >flake.nix
	git add flake.nix
	check_fails nix-flake-check "a broken flake"
	printf '%s\n' '{' '  outputs = _: { };' '}' >flake.nix
	git add flake.nix
	check_passes nix-flake-check
}

# bash_fixture: a library with its bats test, and a script no test runs, with bash's preset written by
# `assay preset bash`, committed; clean for shellcheck under the preset and for shfmt.
bash_fixture() {
	mkdir -p lib test bin
	printf '%s\n' '# shellcheck shell=bash' 'greet() {' '	echo "hello $1"' '}' >lib/greet.sh
	printf '%s\n' '#!/usr/bin/env bash' 'echo "nobody runs me"' >bin/untested
	chmod +x bin/untested
	printf '%s\n' 'setup() {' '	# shellcheck source=lib/greet.sh' '	source "${BATS_TEST_DIRNAME:?}/../lib/greet.sh"' '}' \
		'' '@test "greets" {' '	run greet you' '	[ "$output" = "hello you" ]' '}' >test/greet.bats
	local wrote expected
	wrote=$(devenv shell -- assay preset bash)
	expected=$(printf '%s\n' 'wrote .shellcheckrc' 'wrote .assay-preset.json')
	[ "$wrote" = "$expected" ]
	diff "$ASSAY/preset/bash/1/.shellcheckrc" .shellcheckrc
	git add -A
	git commit --quiet -m fixture
}

@test "bash: assay check --list shows shellcheck and shfmt as fast, bats as full; a tree with no shell file passes" {
	consumer "$ASSAY_LANGUAGES"
	devenv_nix '{ languages.shell.enable = true; }'
	run --separate-stderr devenv shell -- assay check --list
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' bats 'shellcheck (fast)' 'shfmt (fast)')" ]
	run --separate-stderr devenv shell -- assay check
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[1]} == "ok   bats "*"(new code: no lines to cover)" ]]
}

@test "bash: shellcheck and shfmt fail on their defects and pass on the fix; bats' report lists a script no test runs" {
	consumer "$ASSAY_LANGUAGES"
	devenv_nix '{ languages.shell.enable = true; }'
	bash_fixture
	check_passes
	report=$(git rev-parse --absolute-git-dir)/assay/kcov/bats/cobertura.xml
	[ -f "$report" ]
	grep -q 'filename="[^"]*bin/untested"' "$report"
	untested=$(grep -A3 'filename="[^"]*bin/untested"' "$report")
	grep -q 'hits="0"' <<<"$untested"
	greet=$(grep -A3 'filename="[^"]*lib/greet.sh"' "$report")
	grep -q 'hits="1"' <<<"$greet"

	printf '%s\n' '#!/usr/bin/env bash' 'echo $1' >bin/lint
	check_fails shellcheck "SC2086"
	printf '%s\n' '#!/usr/bin/env bash' 'echo "$1"' >bin/lint
	check_passes shellcheck

	# The preset's optional checks hold: a masked return value fails.
	printf '%s\n' '#!/usr/bin/env bash' 'echo "today: $(date)"' >bin/lint
	check_fails shellcheck "SC2312"
	printf '%s\n' '#!/usr/bin/env bash' 'today=$(date)' 'echo "today: $today"' >bin/lint
	check_passes shellcheck

	printf '%s\n' 'f() {' '  echo two spaces' '}' >lib/format.sh
	check_fails shfmt "lib/format.sh"
	printf '%s\n' 'f() {' '	echo a tab' '}' >lib/format.sh
	check_passes shfmt
}

@test "bash: new lines no test runs fail bats through diff-cover; covering them passes; a lower newCode needs a reason" {
	consumer "$ASSAY_LANGUAGES"
	devenv_nix '{ languages.shell.enable = true; }'
	bash_fixture
	printf '%s\n' 'farewell() {' '	echo "bye $1"' '}' >>lib/greet.sh
	# kcov counts the body's line as code, not the braces.
	check_fails bats "(new code: 0 of 1 lines covered, 0%, under 80%)"
	[[ $output == *"lib/greet.sh (0.0%): Missing lines 6"* ]]
	printf '%s\n' '' '@test "says goodbye" {' '	run farewell you' '	[ "$output" = "bye you" ]' '}' >>test/greet.bats
	run --separate-stderr devenv shell -- assay check bats
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[1]} == "ok   bats "*"(new code: 1 of 1 lines covered)" ]]

	devenv_nix '{ languages.shell.enable = true; assay.coverage.newCode = 50; }'
	run devenv shell -- true
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"- assay.coverage.newCode lowered to 50, under assay's 80; set assay.coverage.reason"* ]]
	devenv_nix '{
    languages.shell.enable = true;
    assay.coverage = { newCode = 50; reason = "legacy scripts"; };
  }'
	run --separate-stderr devenv shell -- assay check bats
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "  loosening: new code needs 50% coverage, not assay's 80%: legacy scripts" ]
}

# Run inside the real fixture's devenv, without Git metadata from either the fixture or its parent.
measure_archive() {
	local snapshot=$1
	mkdir "$snapshot"
	git archive -o "$snapshot.tar" HEAD
	tar -xf "$snapshot.tar" -C "$snapshot"
	snapshot_json=$(cd "$snapshot" && devenv shell -- assay measure) || return 1
	echo "$snapshot_json"
	[ ! -e "$snapshot/.git" ]
	jsonschema -i /dev/stdin "$BATS_TEST_DIRNAME/../../schema/measure.json" <<<"$snapshot_json"
}

@test "measure: archived Nix fixture runs in its devenv and validates against the shipped schema" {
	consumer
	shape
	devenv_nix '{ languages.nix.enable = true; }'
	nix_fixture
	git add -A
	git commit --quiet -m nix
	measure_archive "$T/nix-snapshot"
	jq -es 'length == 1 and (.[0] | .failed == [] and .coverage == {} and .lint == [] and .smells == []
		and .duplication != null and any(.loc[]; .language == "Nix" and .lines > 0))' <<<"$snapshot_json"
}

@test "measure: archived bash fixture reports real Cobertura, but null after bats fails" {
	consumer
	shape
	devenv_nix '{ languages.shell.enable = true; }'
	bash_fixture
	measure_archive "$T/bash-snapshot"
	jq -es 'length == 1 and (.[0] | .failed == [] and .coverage.bats == {covered: 1, total: 2}
		and .lint == [] and .smells == [] and .duplication.total > 0
		and any(.loc[]; .language == "Shell" and .lines > 0))' <<<"$snapshot_json"
	sed -i 's/hello you/wrong answer/' test/greet.bats
	git add -A
	git commit --quiet -m failing
	measure_archive "$T/failing-snapshot"
	jq -e '.failed == ["bats"] and .coverage == {bats: null}' <<<"$snapshot_json"
}
