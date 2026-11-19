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

# A synthetic executable runs under the same Bash as Bats, including in a Nix sandbox without /usr/bin/env.
measure_tool() {
	local file=$DEVENV_STUB_PROFILE/$1
	{
		printf '#!%s\n' "$BASH"
		cat
	} >"$file"
	chmod +x "$file"
}

measure_run() {
	env PATH="$DEVENV_STUB_PROFILE:$PATH" "$assay" measure "$@"
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
	measure_tool diff-cover <<<'touch diff-cover-ran; exit 1'
	run --separate-stderr measure_run
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
	measure_tool qlty <<'EOF'
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
	measure_tool jscpd <<'EOF'
set -eu
while [[ $1 != --output ]]; do shift; done
printf '%s\n' '{"statistics":{"total":{"duplicatedLines":4,"lines":21,"percentage":19.05}}}' >"$2/jscpd-report.json"
EOF
	measure_tool scc <<'EOF'
[[ $1 == --format && $2 == json ]] || exit 1
printf '%s\n' '[{"Name":"Shell","Lines":37,"Code":31},{"Name":"Nix","Lines":14,"Code":10}]'
EOF
	run --separate-stderr measure_run
	echo "$output"
	echo "$stderr" >&2
	[ "$status" -eq 0 ]
	jq -es 'length == 1 and (.[0] |
		.lint == [
			{tool:"another-tool",rule:"another-tool:R1",level:"note",count:1},
			{tool:"radarlint-python",rule:"radarlint-python:S1234",level:"error",count:2},
			{tool:"radarlint-python",rule:"radarlint-python:S1234",level:"warning",count:1}] and
		.smells == [{kind:"qlty:nested-control-flow",count:1}] and
		.duplication == {duplicated:4,total:21} and .loc == [{language:"Nix",lines:10},{language:"Shell",lines:31}])' <<<"$output"
	jsonschema -i /dev/stdin "$BATS_TEST_DIRNAME/../schema/measure.json" <<<"$output"

	measure_tool qlty <<<'echo '\''{"runs":[]}'\'''
	measure_tool jscpd <<<'exit 1'
	measure_tool scc <<<'echo not-json'
	run --separate-stderr measure_run
	[ "$status" -eq 0 ]
	[ ! -e .qlty/qlty.toml ]
	jq -e '.lint == [] and .smells == [] and .loc == null and .duplication == null' <<<"$output"
}

@test "measure in a checkout keeps its metadata and reports zero coverage alongside unavailable coverage" {
	local_repo
	mkdir report-is-directory
	check zero 'printf "%s\n" SF:a.sh LF:0 LH:0 end_of_record >zero.info' --coverage zero.info
	check invalid 'printf "%s\n" SF:a.sh LF:1 LH:2 end_of_record >invalid.info' --coverage invalid.info
	check blocked 'printf "%s\n" "check still ran" >ran' --coverage report-is-directory
	before=$(git rev-parse HEAD)
	run --separate-stderr measure_run
	[ "$status" -eq 0 ]
	jq -e '.failed == [] and .coverage == {zero:{covered:0,total:0}, invalid:null, blocked:null}' <<<"$output"
	holds ran 'check still ran'
	[ -d report-is-directory ]
	[ -d .git ]
	prints "$before" git rev-parse HEAD
}

@test "measure refuses to overwrite an archive's qlty settings or write through a symlink" {
	local_repo
	mkdir .qlty "$T/other"
	printf 'kept settings\n' >.qlty/qlty.toml
	archive_fixture
	measure_tool qlty <<<'touch qlty-ran; exit 1'
	run --separate-stderr measure_run
	[ "$status" -eq 0 ]
	jq -e '.lint == null and .smells == null and .failed == []' <<<"$output"
	[[ $stderr == *"archive already contains qlty configuration"* ]]
	holds .qlty/qlty.toml 'kept settings'
	[ ! -e qlty-ran ] && [ ! -e .git ]

	mv .qlty "$T/original-qlty"
	ln -s "$T/other" .qlty
	run --separate-stderr measure_run
	[ "$status" -eq 0 ]
	jq -e '.lint == null and .smells == null and .failed == []' <<<"$output"
	[[ $stderr == *"cannot prepare qlty configuration through a symlink"* ]]
	[ -L .qlty ] && [ ! -e "$T/other/qlty.toml" ] && [ ! -e qlty-ran ] && [ ! -e .git ]
}

@test "measure reports smells independently when the lint invocation is unsuccessful" {
	local_repo
	archive_fixture
	measure_tool qlty <<'EOF'
case $2 in
	check) echo '{"runs":[{"invocations":[{"executionSuccessful":false}],"results":[]}]}' ;;
	smells) echo '{"runs":[{"tool":{"driver":{"name":"qlty"}},"results":[{"ruleId":"nested-control-flow"}]}]}' ;;
	*) exit 1 ;;
esac
EOF
	run --separate-stderr measure_run
	[ "$status" -eq 0 ]
	jq -e '.lint == null and .smells == [{kind:"nested-control-flow",count:1}]' <<<"$output"
	[[ $stderr == *"could not measure lint"* ]]
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
