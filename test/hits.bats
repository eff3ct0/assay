# shellcheck disable=SC2030,SC2031 # bats runs each test in a process of its own: what one test sets, no other reads
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

# The hits log: one JSON line per `assay check` run, appended to ASSAY_HITS_LOG when it is set.

# hit <n>: the hits log's line <n>.
hit() { sed -n "$1p" "$ASSAY_HITS_LOG"; }

@test "each assay check run appends one check line with the common fields and the run's" {
	local_repo
	check a true --fast
	check b "exit 1"
	export ASSAY_HITS_LOG=$T/state/assay/hits.jsonl
	run "$assay" check
	[ "$status" -eq 1 ]
	[ "$(wc -l <"$ASSAY_HITS_LOG")" -eq 1 ]
	hit 1 | jq -e --arg repo "$(pwd -P)" '
    (keys == ["agent", "exit", "failed", "mode", "only", "repo", "seconds", "source", "time", "v"])
    and .v == 1
    and (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .source == "check" and .repo == $repo and .agent == null
    and .mode == "full" and .only == [] and (.seconds | type) == "number" and .seconds >= 0
    and .failed == ["b"] and .exit == 1'
	ASSAY_AGENT=claude-code run "$assay" check --fast a
	[ "$status" -eq 0 ]
	[ "$(wc -l <"$ASSAY_HITS_LOG")" -eq 2 ]
	hit 2 | jq -e '.agent == "claude-code" and .mode == "fast" and .only == ["a"] and .failed == [] and .exit == 0'
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
	hit 1 | jq -e --arg repo "$(cd "$T/work" && pwd -P)" '.repo == $repo and .only == ["c", "a", "c"] and .agent == null'
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
	[ "$(wc -l <"$ASSAY_HITS_LOG")" -eq 2 ]
	hit 1 | jq -e '.exit == 2 and .failed == [] and .only == []'
	hit 2 | jq -e '.exit == 2 and .only == ["nope"]'
	run "$assay" check --list
	run "$assay" check --nope
	run "$assay" check --help
	run "$assay" --help
	[ "$(wc -l <"$ASSAY_HITS_LOG")" -eq 2 ]
}

@test "outside the devenv, the run writes one line: the repo's assay writes it, the delegating one nothing" {
	local_repo
	devenv_files yes
	check a "exit 1"
	outside_devenv
	export ASSAY_HITS_LOG=$T/hits.jsonl
	run "$assay" check
	[ "$status" -eq 1 ]
	[ "$(wc -l <"$ASSAY_HITS_LOG")" -eq 1 ]
	hit 1 | jq -e '.failed == ["a"] and .exit == 1'
	rm devenv.nix
	run "$assay" check
	[ "$status" -eq 2 ]
	[ "$(wc -l <"$ASSAY_HITS_LOG")" -eq 1 ]
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
		[ "$(untimed "$output")" = "$expected_out" ]
		[ "$stderr" = "$expected_err" ]
	done
	if [ "$(id -u)" -ne 0 ]; then [ -z "$(ls "$T/readonly")" ]; fi
	[ -z "$(git status --porcelain)" ]
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
	hit 1 | jq -e '.exit == 2 and .failed == ["fails"]'
}
