bats_require_minimum_version 1.5.0
# shellcheck source=test/devenv/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

@test "devenv test runs every check; git commit runs only the fast ones, through the assay hook" {
	consumer
	devenv_nix "{
    assay.checks.quick = { exec = \"echo quick >>$T/ran\"; fast = true; };
    assay.checks.full.exec = \"echo full >>$T/ran\";
  }"
	run devenv test
	echo "$output"
	[ "$status" -eq 0 ]
	# The hook (assay check --fast) runs over all files first, then enterTest (assay check), in name order.
	[ "$(cat "$T/ran")" = "$(printf 'quick\nfull\nquick')" ]
	[ "$(hook entry)" = '"devenv shell -- assay check --fast"' ]
	[ "$(hook pass_filenames)" = false ]
	[ "$(hook always_run)" = true ]
	rm "$T/ran"
	git add devenv.nix
	run git commit -m checks
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *"assay check --fast"*Passed* ]]
	[ "$(cat "$T/ran")" = quick ]
}

@test "a failing check fails devenv test; a failing fast check also fails git commit" {
	consumer
	devenv_nix '{
    assay.checks.quick = { exec = "true"; fast = true; };
    assay.checks.full.exec = "echo full failed; exit 3";
  }'
	run devenv test
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"FAIL full"*"(exit 3)"* ]]
	git add devenv.nix
	run git commit -m "full fails"
	echo "$output"
	[ "$status" -eq 0 ]
	devenv_nix '{
    assay.checks.quick = { exec = "echo quick failed; exit 4"; fast = true; };
  }'
	git add devenv.nix
	run git commit -m "quick fails"
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"FAIL quick"*"(exit 4)"* ]]
	[ "$(git log -1 --format=%s)" = "full fails" ]
	run devenv test
	[ "$status" -ne 0 ]
}

@test "inside devenv shell: assay check reports, selects and lists; ASSAY_SEED comes from assay.seed" {
	consumer
	# shellcheck disable=SC2016 # the check's own $ASSAY_SEED
	devenv_nix '{
    assay.checks.lint = { exec = "echo lint"; fast = true; };
    assay.checks.test.exec = "echo seed=$ASSAY_SEED; exit 1";
    assay.checks.cargo = { exec = "cargo test"; requires = "Cargo.toml"; };
  }'
	run --separate-stderr devenv shell -- assay check
	echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "assay check · base main@$(git rev-parse --short HEAD) (fork-point)" ]
	[ "${lines[1]}" = "  skipped: cargo (no Cargo.toml)" ]
	[ "${lines[2]}" = "skip cargo (no Cargo.toml)" ]
	[[ ${lines[3]} =~ ^ok\ \ \ lint\ [0-9.]+s$ ]]
	[[ ${lines[4]} =~ ^FAIL\ test\ [0-9.]+s\ \(exit\ 1\)$ ]]
	[[ $output == *$'\nseed=42\nlog: '"$(git rev-parse --absolute-git-dir)/assay/test.log"$'\n'* ]]
	[[ ${lines[-1]} == "1 of 3 checks failed in "*"; rerun: assay check test" ]]
	run --separate-stderr devenv shell -- assay check --fast
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "assay check --fast · base main@$(git rev-parse --short HEAD) (fork-point)" ]
	run --separate-stderr devenv shell -- assay check --list
	[ "$output" = "$(printf 'cargo\nlint (fast)\ntest')" ]
	run --separate-stderr devenv shell -- assay check nope
	[ "$status" -eq 2 ]
	[[ $stderr == *"assay: no check named 'nope'"* ]]
	devenv_nix '{ assay.seed = 7; }'
	run --separate-stderr devenv shell -- printenv ASSAY_SEED
	[ "$output" = 7 ]
}

@test "turning a default check off needs a reason, which the header then lists" {
	consumer "$ASSAY_WITH_DEFAULT"
	run --separate-stderr devenv shell -- assay check --list
	[ "$output" = "demo (fast)" ]
	devenv_nix '{ assay.checks.demo.enable = false; }'
	run devenv shell -- true
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"a loosening needs a reason:"* ]]
	[[ $output == *"- demo turned off; set assay.checks.demo.reason"* ]]
	devenv_nix '{ assay.checks.demo = { enable = false; reason = "too slow on this repo"; }; }'
	run --separate-stderr devenv shell -- assay check
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "  loosening: demo is off: too slow on this repo" ]
}

@test "redefining a default check's exec needs a reason, which the header then lists" {
	consumer "$ASSAY_WITH_DEFAULT"
	devenv_nix '{ assay.checks.demo.exec = "echo mine"; }'
	run devenv shell -- true
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"- demo's exec redefined; set assay.checks.demo.reason"* ]]
	devenv_nix '{ assay.checks.demo = { exec = "echo mine"; reason = "the repo has its own"; }; }'
	run --separate-stderr devenv shell -- assay check
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "  loosening: demo runs the repo's own exec: the repo has its own" ]
	# Changing another field of a default is no loosening.
	devenv_nix '{ assay.checks.demo.requires = "*.md"; }'
	run --separate-stderr devenv shell -- assay check
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "  skipped: demo (no *.md)" ]
}

@test "a plain definition in the repo changes a field of the hook" {
	consumer
	devenv_nix '{ git-hooks.hooks.assay.always_run = false; }'
	run devenv shell -- true
	[ "$status" -eq 0 ]
	[ "$(hook always_run)" = false ]
	[ "$(hook entry)" = '"devenv shell -- assay check --fast"' ]
}

@test "outside the devenv, plain assay check re-executes itself through devenv shell" {
	consumer
	devenv_nix '{
    assay.checks.lint = { exec = "echo lint"; fast = true; };
    assay.checks.test.exec = "echo tests failed; exit 1";
  }'
	mkdir sub
	cd sub
	run --separate-stderr "$ASSAY/assay.sh" check --list
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf 'lint (fast)\ntest')" ]
	run --separate-stderr "$ASSAY/assay.sh" check
	echo "$output"
	[ "$status" -eq 1 ]
	[[ ${lines[-1]} == "1 of 2 checks failed in "*"; rerun: assay check test" ]]
}

@test "a repo without devenv.nix, or whose devenv does not import assay's module, exits 2 naming docs/adoption.md" {
	mkdir "$T/repo"
	cd "$T/repo"
	git init --quiet
	git commit --quiet --allow-empty -m init
	run --separate-stderr "$ASSAY/assay.sh" check
	[ "$status" -eq 2 ]
	[[ $stderr == *"has no devenv.nix"*"docs/adoption.md" ]]
	printf '%s\n' inputs: '  nixpkgs:' "    url: github:NixOS/nixpkgs/$NIXPKGS_REV" >devenv.yaml
	echo '{ }' >devenv.nix
	printf '%s\n' .devenv/ .devenv.flake.nix devenv.lock >.gitignore
	git add -A
	git commit --quiet -m devenv
	run --separate-stderr "$ASSAY/assay.sh" check
	echo "$stderr"
	[ "$status" -eq 2 ]
	[[ $stderr == *"does not import assay's module"*"docs/adoption.md" ]]
}

@test "assay adopts itself: nix run . -- check --list goes through its devenv, and git commit runs the fast checks" {
	copy_assay "$T/self"
	cd "$T/self"
	run --separate-stderr nix run . -- check --list
	echo "$stderr"
	[ "$status" -eq 0 ]
	[ "$output" = bats ]
	run git commit --allow-empty -m "an empty commit"
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *"assay check --fast"*Passed* ]]
}
