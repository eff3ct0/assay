bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# Presets: `assay preset`, which writes a language's preset into the repo and merges later versions in, the built-in
# `preset` check, and the header line of `assay check` for a preset that moved. The presets are this checkout's
# preset/, or a copy with a synthetic later version (bash_version_2).

# bash_version_2: a copy of assay's presets with a synthetic version 2 of bash's, whose .shellcheckrc adds a line above
# the enable line, made the presets assay reads (assay_presets).
bash_version_2() {
	cp -r "$BATS_TEST_DIRNAME/../preset" "$T/presets"
	mkdir "$T/presets/bash/2"
	printf '%s\n' 'external-sources=true' \
		'enable=check-extra-masked-returns,check-set-e-suppressed,check-unassigned-uppercase' \
		>"$T/presets/bash/2/.shellcheckrc"
	export assay_presets=$T/presets
}

# bash_repo: a repo whose devenv enables bash, with a committed shell script, as the current directory.
bash_repo() {
	local_repo
	languages bash
	printf '%s\n' '#!/usr/bin/env bash' 'echo "hello"' >build.sh
	git add build.sh
	git commit --quiet -m script
}

@test "the preset check fails while an enabled language's preset applies and the record does not list it" {
	bash_repo
	run --separate-stderr "$assay" builtin preset
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *"bash's preset applies (the repo tracks the shell script build.sh)"* ]]
	[ "${lines[-1]}" = "run: assay preset bash" ]
}

@test "assay preset writes the missing files and the record, prints both paths, and the preset check then passes" {
	bash_repo
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 0 ]
	output_is 'wrote .shellcheckrc' 'wrote .assay-preset.json'
	diff "$BATS_TEST_DIRNAME/../preset/bash/1/.shellcheckrc" .shellcheckrc
	holds .assay-preset.json '{' '  "bash": 1' '}'
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	# Run again, it has nothing to do.
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is "bash's preset 1: up to date"
}

@test "an adoption keeps the repo's own .shellcheckrc, shows it against the preset, records the version and exits 1" {
	bash_repo
	printf '%s\n' 'disable=SC2034' >.shellcheckrc
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 1 ]
	output_is 'kept .shellcheckrc' 'wrote .assay-preset.json' '' \
		"--- .shellcheckrc, kept, against bash's preset 1 (the + lines are the preset's)" \
		'@@ -1 +1 @@' '-disable=SC2034' \
		'+enable=check-extra-masked-returns,check-set-e-suppressed,check-unassigned-uppercase' '' \
		".shellcheckrc differs from bash's preset 1: extend it by hand to hold what the preset holds (the + lines above), keeping what the repo needs of its own"
	holds .shellcheckrc 'disable=SC2034'
	holds .assay-preset.json '{' '  "bash": 1' '}'
	# Extended by hand, the next run has nothing to do.
	printf '%s\n' 'disable=SC2034' \
		'enable=check-extra-masked-returns,check-set-e-suppressed,check-unassigned-uppercase' >.shellcheckrc
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is "bash's preset 1: up to date"
}

@test "an adoption whose file already is the preset's keeps it and exits 0" {
	bash_repo
	cp "$BATS_TEST_DIRNAME/../preset/bash/1/.shellcheckrc" .shellcheckrc
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is 'kept .shellcheckrc' 'wrote .assay-preset.json'
}

@test "with a shellcheckrc, the preset counts it as shellcheck's file and writes no .shellcheckrc beside it" {
	bash_repo
	printf '%s\n' 'disable=SC2034' >shellcheckrc
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "kept shellcheckrc" ]
	[ "${lines[2]}" = "--- shellcheckrc, kept, against bash's preset 1 (the + lines are the preset's)" ]
	[ ! -e .shellcheckrc ]
	holds shellcheckrc 'disable=SC2034'
}

@test "a repo at version 1 with a local edit merges version 2 cleanly: exit 0, the record raised" {
	bash_repo
	"$assay" preset >/dev/null
	echo 'disable=SC1091' >>.shellcheckrc
	bash_version_2
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 0 ]
	output_is 'merged .shellcheckrc' 'wrote .assay-preset.json'
	holds .shellcheckrc 'external-sources=true' \
		'enable=check-extra-masked-returns,check-set-e-suppressed,check-unassigned-uppercase' 'disable=SC1091'
	holds .assay-preset.json '{' '  "bash": 2' '}'
}

@test "a clashing edit leaves conflict markers and exits 1; the record is raised, so the next run merges nothing" {
	bash_repo
	"$assay" preset >/dev/null
	printf '%s\n' 'enable=check-extra-masked-returns' >.shellcheckrc
	bash_version_2
	printf '%s\n' 'enable=all' >"$T/presets/bash/2/.shellcheckrc"
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 1 ]
	output_is 'conflict .shellcheckrc' 'wrote .assay-preset.json' '' \
		".shellcheckrc conflicts with bash's preset 2: resolve its markers (<<<<<<< the repo's lines, ||||||| bash's preset 1, >>>>>>> bash's preset 2)"
	holds .shellcheckrc '<<<<<<< .shellcheckrc' 'enable=check-extra-masked-returns' "||||||| bash's preset 1" \
		'enable=check-extra-masked-returns,check-set-e-suppressed,check-unassigned-uppercase' '=======' 'enable=all' \
		">>>>>>> bash's preset 2"
	holds .assay-preset.json '{' '  "bash": 2' '}'
	# Until the markers are resolved, every run reports them.
	run --separate-stderr "$assay" preset
	[ "$status" -eq 1 ]
	output_is 'conflict .shellcheckrc' '' \
		".shellcheckrc holds the markers of a conflict with bash's preset: resolve them"
	printf '%s\n' 'enable=all' >.shellcheckrc
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is "bash's preset 2: up to date"
}

@test "version 2 merges into a shellcheckrc the repo has instead of .shellcheckrc" {
	bash_repo
	cp "$BATS_TEST_DIRNAME/../preset/bash/1/.shellcheckrc" shellcheckrc
	"$assay" preset >/dev/null
	bash_version_2
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is 'merged shellcheckrc' 'wrote .assay-preset.json'
	[ ! -e .shellcheckrc ]
	diff "$T/presets/bash/2/.shellcheckrc" shellcheckrc
}

@test "with the record behind the pinned preset, assay check's header names the language, and nothing fails" {
	bash_repo
	"$assay" preset >/dev/null
	check passes true
	bash_version_2
	run --separate-stderr "$assay" check --base HEAD
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "  preset behind: bash 1 → 2 (assay preset bash)" ]
	[ "${lines[2]}" = "ok   passes ${lines[2]#ok   passes }" ]
	# Every language the record holds, enabled or not; not one at the pinned version.
	languages
	run --separate-stderr "$assay" check --base HEAD
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "  preset behind: bash 1 → 2 (assay preset bash)" ]
	languages bash
	"$assay" preset >/dev/null
	run --separate-stderr "$assay" check --base HEAD
	[[ ${lines[1]} == "ok   passes "* ]]
}

@test "outside the devenv, assay preset re-executes itself through devenv shell; without a git repo it exits 2" {
	bash_repo
	devenv_files yes
	outside_devenv
	mkdir sub
	cd sub
	run --separate-stderr "$assay" preset bash
	echo "$output"
	[ "$status" -eq 0 ]
	output_is 'wrote .shellcheckrc' 'wrote .assay-preset.json'
	[ -f "$T/work/.shellcheckrc" ]
	calls=$(cat "$T/devenv.calls")
	[[ $calls == "$(printf %q "$T/work") shell -- "*" preset bash" ]]
	mkdir "$T/nowhere"
	cd "$T/nowhere"
	run --separate-stderr "$assay" preset
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: not in a git working tree" ]
}

@test "with no language named, only the enabled languages whose preset applies: a tracked script, found by its shebang" {
	local_repo
	languages bash nix
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is "no preset to apply: no language this repo's devenv enables has a preset that applies"
	# An untracked script does not count, nor does a tracked file that is not a script.
	printf '%s\n' '#!/bin/sh' 'true' >tool
	echo 'notes' >notes.txt
	git add notes.txt
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 0 ]
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	[ ! -e .shellcheckrc ]
	git add tool
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 1 ]
	[[ $output == *"(the repo tracks the shell script tool)"* ]]
	languages nix
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 0 ]
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	[ ! -e .shellcheckrc ]
}

@test "without shfmt, which tells shell scripts apart, the preset check exits 127 and assay preset exits 2" {
	bash_repo
	local dir path=""
	local -a dirs
	IFS=: read -ra dirs <<<"$PATH"
	for dir in "${dirs[@]}"; do
		if [ ! -x "$dir/shfmt" ]; then path+=$dir:; fi
	done
	run -127 --separate-stderr env PATH="${path%:}" "$assay" builtin preset
	[ "$stderr" = "assay: cannot find shfmt on the PATH, which tells shell scripts apart" ]
	run --separate-stderr env PATH="${path%:}" "$assay" preset
	[ "$status" -eq 2 ]
}

@test "a language named is taken as given; one without a preset is exit 2, naming the ones that have one" {
	local_repo
	run --separate-stderr "$assay" preset bash bash
	[ "$status" -eq 0 ]
	output_is 'wrote .shellcheckrc' 'wrote .assay-preset.json'
	run --separate-stderr "$assay" preset nix
	[ "$status" -eq 2 ]
	[ "${stderr_lines[0]}" = "assay: assay has no preset for 'nix'; it has one for: bash python" ]
	run --separate-stderr "$assay" preset --force
	[ "$status" -eq 2 ]
	[ "${stderr_lines[0]}" = "assay: unknown option '--force'" ]
}

@test "a record that cannot be read: assay preset and the preset check exit 2, and assay check's header goes on" {
	bash_repo
	check passes true
	echo '{"bash": "1"}' >.assay-preset.json
	run --separate-stderr "$assay" preset
	[ "$status" -eq 2 ]
	[ "$stderr" = 'assay: cannot read .assay-preset.json: bash: the version must be a positive integer, not "1"' ]
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 2 ]
	echo '{"bash": 1} {}' >.assay-preset.json
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 2 ]
	[ "$stderr" = 'assay: cannot read .assay-preset.json: expected one JSON document, found 2' ]
	run --separate-stderr "$assay" check --base HEAD
	[ "$status" -eq 0 ]
	[[ ${lines[1]} == "ok   passes "* ]]
}

@test "a record newer than assay's preset, or naming a version assay lacks, is exit 2; other languages are kept" {
	bash_repo
	echo '{"bash": 2}' >.assay-preset.json
	run --separate-stderr "$assay" preset
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: .assay-preset.json records bash's preset 2, newer than this assay's 1: update assay (devenv update assay)" ]
	bash_version_2
	rm -r "$T/presets/bash/1"
	echo '{"bash": 1}' >.assay-preset.json
	run --separate-stderr "$assay" preset
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: .assay-preset.json records bash's preset 1, which this assay does not hold" ]
	unset assay_presets
	printf '%s\n' '{"python": 3, "bash": 1}' >.assay-preset.json
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is 'wrote .shellcheckrc'
	run --separate-stderr "$assay" preset
	output_is "bash's preset 1: up to date"
	holds .assay-preset.json '{"python": 3, "bash": 1}'
}

@test "a file a later version adds is written when the repo lacks it, and merged from an empty base when it has one" {
	bash_repo
	"$assay" preset >/dev/null
	bash_version_2
	mkdir -p "$T/presets/bash/2/conf"
	echo 'new=1' >"$T/presets/bash/2/conf/added"
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is 'merged .shellcheckrc' 'wrote conf/added' 'wrote .assay-preset.json'
	holds conf/added 'new=1'
	echo '{"bash": 1}' >.assay-preset.json
	echo 'mine=1' >conf/added
	run --separate-stderr "$assay" preset
	[ "$status" -eq 1 ]
	output_is 'conflict conf/added' 'wrote .assay-preset.json' '' \
		"conf/added conflicts with bash's preset 2: resolve its markers (<<<<<<< the repo's lines, ||||||| bash's preset 1, >>>>>>> bash's preset 2)"
}

@test "assay's presets: each language's versions run from 1 without a gap, and none is empty" {
	local dir lang v
	local -a versions files
	shopt -s nullglob dotglob globstar
	for dir in "$BATS_TEST_DIRNAME"/../preset/*/; do
		lang=$(basename "$dir")
		versions=("$dir"*/)
		[ ${#versions[@]} -gt 0 ]
		for ((v = 1; v <= ${#versions[@]}; v++)); do
			[ -d "$dir$v" ] || {
				echo "$lang has no version $v" >&2
				return 1
			}
			files=("$dir$v"/**)
			[ ${#files[@]} -gt 0 ]
		done
	done
}
