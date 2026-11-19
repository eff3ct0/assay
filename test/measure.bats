# shellcheck disable=SC2016 # literal shell and jq in the fixtures
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

archive_fixture() {
	git add -A
	git commit --quiet --allow-empty -m snapshot
	mkdir "$T/archive"
	git archive -o "$T/archive.tar" HEAD
	tar -xf "$T/archive.tar" -C "$T/archive"
	cd "$T/archive" || return 1
	[ ! -e .git ]
}

@test "measure delegates in a git archive without a base or a hit" {
	local_repo
	devenv_files yes
	archive_fixture
	check tree 'test -z "${ASSAY_BASE+x}" && git ls-files --error-unmatch a.txt'
	export ASSAY_BASE=not-a-revision ASSAY_HITS_LOG=$T/hits
	printf 'existing hit\n' >"$ASSAY_HITS_LOG"
	outside_devenv
	run --separate-stderr "$assay" measure
	echo "$output"
	[ "$status" -eq 0 ]
	jq -es 'length == 1 and (.[0] | .failed == [] and .seconds >= 0)' <<<"$output"
	[ -s "$DEVENV_STUB_CALLS" ]
	[ ! -e .git ]
	prints 'existing hit' cat "$ASSAY_HITS_LOG"
}

@test "measure counts successful coverage reports, not failed, missing, stale or skipped reports" {
	local_repo
	cat >stale.info <<'EOF'
SF:a.sh
LH:1
LF:1
end_of_record
EOF
	archive_fixture
	check lcov 'printf "%s\n" SF:a.sh DA:1,0 DA:2,2 end_of_record SF:b.sh LF:3 LH:2 end_of_record >"$ASSAY_DIR/actual.info"' \
		--coverage '$ASSAY_DIR/actual.info'
	check cobertura 'printf "%s\n" "<?xml version=\"1.0\"?>" "<coverage lines-valid=\"7\" lines-covered=\"4\"/>" >actual.xml' \
		--coverage actual.xml --fast
	check failed 'cp actual.xml fail.xml; exit 1' --coverage fail.xml
	check stale true --coverage stale.info
	check missing true --coverage missing.info
	check malformed 'echo "<coverage lines-valid=\"4\"" >broken.xml' --coverage broken.xml
	check skipped 'touch skipped-check-ran; exit 1' --coverage skipped.xml --requires '**/*.absent'
	for name in commit-trailers findings suppressions mutation diff-cover osv-scanner cargo-deny-advisories; do
		check "$name" 'touch excluded-check-ran; exit 1'
	done
	check disabled 'touch excluded-check-ran; exit 1' --off
	printf '#!/bin/sh\ntouch diff-cover-ran; exit 1\n' >"$DEVENV_STUB_PROFILE/diff-cover"
	chmod +x "$DEVENV_STUB_PROFILE/diff-cover"
	run --separate-stderr env PATH="$DEVENV_STUB_PROFILE:$PATH" "$assay" measure
	echo "$output"
	echo "$stderr" >&2
	[ "$status" -eq 0 ]
	[ ! -e diff-cover-ran ] && [ ! -e excluded-check-ran ] && [ ! -e skipped-check-ran ]
	jq -es 'length == 1 and (.[0] | .failed == ["failed"] and
		.coverage == {cobertura: {covered: 4, total: 7}, lcov: {covered: 3, total: 5},
			failed: null, malformed: null, missing: null, skipped: null, stale: null})' <<<"$output"
	jsonschema -i /dev/stdin "$BATS_TEST_DIRNAME/../schema/measure.json" <<<"$output"
}

@test "measure reports raw analyzer counts and distinguishes unavailable from an empty result" {
	local_repo
	archive_fixture
	cat >"$DEVENV_STUB_PROFILE/qlty" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ $1 == --no-upgrade-check && $3 == --all && $4 == --sarif ]]
case $2 in
check)
	cat <<'JSON'
{"runs":[{"tool":{"driver":{"name":"qlty"}},"results":[
	{"ruleId":"radarlint-python:S1234","level":"error"},
	{"ruleId":"radarlint-python:S1234","level":"error"},
	{"ruleId":"radarlint-python:S1234"},
	{"ruleId":"another-tool:R1","level":"note"}
]}]}
JSON
	;;
smells)
	printf '%s\n' '{"runs":[{"tool":{"driver":{"name":"qlty"}},"results":[{"ruleId":"qlty:nested-control-flow"}]}]}'
	;;
*) exit 1 ;;
esac
EOF
	cat >"$DEVENV_STUB_PROFILE/jscpd" <<'EOF'
#!/usr/bin/env bash
set -eu
while [[ $1 != --output ]]; do shift; done
printf '%s\n' '{"statistics":{"total":{"duplicatedLines":4,"lines":21,"percentage":19.05}}}' >"$2/jscpd-report.json"
EOF
	cat >"$DEVENV_STUB_PROFILE/scc" <<'EOF'
#!/usr/bin/env bash
[[ $1 == --format && $2 == json ]] || exit 1
printf '%s\n' '[{"Name":"Shell","Lines":37,"Code":31},{"Name":"Nix","Lines":14,"Code":10}]'
EOF
	chmod +x "$DEVENV_STUB_PROFILE/"{qlty,jscpd,scc}
	run --separate-stderr env PATH="$DEVENV_STUB_PROFILE:$PATH" "$assay" measure
	[ "$status" -eq 0 ]
	jq -es 'length == 1 and (.[0] |
		.lint == [
			{tool:"another-tool",rule:"another-tool:R1",level:"note",count:1},
			{tool:"radarlint-python",rule:"radarlint-python:S1234",level:"error",count:2},
			{tool:"radarlint-python",rule:"radarlint-python:S1234",level:"warning",count:1}] and
		.smells == [{kind:"qlty:nested-control-flow",count:1}] and
		.duplication == {duplicated:4,total:21} and .loc == [{language:"Nix",lines:10},{language:"Shell",lines:31}])' <<<"$output"
	jsonschema -i /dev/stdin "$BATS_TEST_DIRNAME/../schema/measure.json" <<<"$output"

	printf '#!/bin/sh\necho '\''{"runs":[]}'\''\n' >"$DEVENV_STUB_PROFILE/qlty"
	printf '#!/bin/sh\nexit 1\n' >"$DEVENV_STUB_PROFILE/jscpd"
	printf '#!/bin/sh\necho not-json\n' >"$DEVENV_STUB_PROFILE/scc"
	run --separate-stderr env PATH="$DEVENV_STUB_PROFILE:$PATH" "$assay" measure
	[ "$status" -eq 0 ]
	[ ! -e .qlty/qlty.toml ]
	jq -e '.lint == [] and .smells == [] and .loc == null and .duplication == null' <<<"$output"
}

@test "measure exits 2 without a devenv importing assay" {
	local_repo
	outside_devenv
	run --separate-stderr "$assay" measure
	[ "$status" -eq 2 ]
	[ -z "$output" ]
	[[ $stderr == *"has no devenv.nix"* ]]
	devenv_files no
	archive_fixture
	run --separate-stderr "$assay" measure
	[ "$status" -eq 2 ]
	[ -z "$output" ]
	[[ $stderr == *"does not import assay's module"* ]]
}
