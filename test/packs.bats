bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# Rule packs: the ones assay ships (packs/, none yet) and the ones its tests turn on (test/packs/). Each is an
# ast-grep project of its own, whose rules hold what any rule holds.

# packs: every pack's directory, one per line.
packs() {
	local dir
	for dir in "$BATS_TEST_DIRNAME"/../packs/*/ "$BATS_TEST_DIRNAME"/packs/*/; do
		if [ -d "$dir" ]; then echo "${dir%/}"; fi
	done
}

@test "every rule pack passes its own tests" {
	local pack n=0
	packs >"$T/packs"
	while IFS= read -r pack; do
		run --separate-stderr ast-grep test -c "$pack/sgconfig.yml" --skip-snapshot-tests --color never
		echo "$pack: $output$stderr"
		[ "$status" -eq 0 ]
		n=$((n + 1))
	done <"$T/packs"
	[ "$n" -ge 1 ]
}

@test "every rule in a pack is an error with a message, a note ending in the closing line, and both kinds of test case" {
	local pack rule id tests note closing="If the rule is wrong here, stop and tell the user; exceptions go in the rule's own file."
	packs >"$T/packs"
	while IFS= read -r pack; do
		prints '[["rules"],"rule-tests"]' yq -o=json -I=0 '[.ruleDirs, .testConfigs[].testDir]' "$pack/sgconfig.yml"
		for rule in "$pack"/rules/*.yml; do
			echo "$rule"
			id=$(yq '.id' "$rule")
			[ "$(basename "$rule" .yml)" = "$id" ]
			prints error yq '.severity' "$rule"
			prints true yq '.message | test("^[^\n]+$")' "$rule"
			note=$(yq '.note' "$rule")
			[[ $note == "Why: "*$'\nFix: '*$'\nNot a fix: '*$'\n'"$closing" ]]
			tests=$pack/rule-tests/$id-test.yml
			prints "$id" yq '.id' "$tests"
			prints true yq '(.invalid | length) > 0 and (.valid | length) > 0' "$tests"
		done
	done <"$T/packs"
}
