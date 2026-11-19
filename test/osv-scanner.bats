bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# `assay builtin osv-scanner`: the advisories on the dependency versions a change adds or changes, against the base,
# with the osv-scanner stub (test/stub/osv-scanner), which reads a lockfile as lines "<name> <version> [<advisory>...]".
# The fixtures' package versions and advisory records are synthetic.

# osv_calls: the stub logs its calls to $T/osv.calls.
osv_calls() { export OSV_STUB_CALLS=$T/osv.calls; }

# lock <file> <line>...: write a stub lockfile.
lock() {
	local file=$1
	shift
	mkdir -p "$(dirname "$file")"
	printf '%s\n' "$@" >"$file"
}

@test "an advisory on a version the change adds fails; the same version already locked at the base passes" {
	local_repo
	lock uv.lock 'idna 3.7'
	git add uv.lock
	git commit --quiet -m lock
	lock uv.lock 'idna 3.7' 'urllib3 2.2.1 GHSA-34jh+PYSEC-1995'
	run --separate-stderr "$assay" builtin osv-scanner --base HEAD uv.lock
	echo "$output"
	[ "$status" -eq 1 ]
	output_is "uv.lock: urllib3 2.2.1 (PyPI): GHSA-34jh, PYSEC-1995: GHSA-34jh's summary; fixed in 2.2.1.1" \
		"1 advisory on dependency versions this change adds or changes: move each package to a version that fixes it, or leave it out of the change; an advisory that does not apply goes in osv-scanner.toml, with its reason."
	git commit --quiet -am "urllib3"
	run --separate-stderr "$assay" builtin osv-scanner --base HEAD uv.lock
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "advisories on versions the change leaves alone are never shown; a version it changes is new again" {
	local_repo
	lock uv.lock 'idna 3.6 GHSA-old' 'urllib3 2.2.1 GHSA-1'
	git add uv.lock
	git commit --quiet -m lock
	lock uv.lock 'idna 3.6 GHSA-old' 'urllib3 2.2.2 GHSA-1' 'jinja2 3.1.4 PYSEC-9 GHSA-8'
	run --separate-stderr "$assay" builtin osv-scanner --base HEAD uv.lock
	echo "$output"
	[ "$status" -eq 1 ]
	output_is 'uv.lock: jinja2 3.1.4 (PyPI): GHSA-8: GHSA-8'"'"'s summary; fixed in 3.1.4.1' \
		'uv.lock: jinja2 3.1.4 (PyPI): PYSEC-9: no summary; fixed in 3.1.4.1' \
		'uv.lock: urllib3 2.2.2 (PyPI): GHSA-1: GHSA-1'"'"'s summary; fixed in 2.2.2.1' \
		"3 advisories on dependency versions this change adds or changes: move each package to a version that fixes it, or leave it out of the change; an advisory that does not apply goes in osv-scanner.toml, with its reason."
	[[ $output != *idna* ]]
}

@test "the base's copy keeps the lockfile's name; a lockfile the base lacks makes all its advisories new" {
	local_repo
	osv_calls
	lock app/uv.lock 'urllib3 2.2.1 GHSA-1'
	run --separate-stderr "$assay" builtin osv-scanner --base HEAD ./app/uv.lock
	echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = "app/uv.lock: urllib3 2.2.1 (PyPI): GHSA-1: GHSA-1's summary; fixed in 2.2.1.1" ]
	holds "$OSV_STUB_CALLS" uv.lock
	git add app
	git commit --quiet -m lock
	: >"$OSV_STUB_CALLS"
	run --separate-stderr "$assay" builtin osv-scanner --base HEAD app/uv.lock
	[ "$status" -eq 0 ]
	holds "$OSV_STUB_CALLS" 'uv.lock uv.lock'
}

@test "nothing to scan passes: a lockfile the working tree lacks is not scanned, one with no package passes" {
	local_repo
	osv_calls
	run --separate-stderr "$assay" builtin osv-scanner --base HEAD uv.lock pnpm-lock.yaml
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ ! -e "$OSV_STUB_CALLS" ]
	: >uv.lock
	run --separate-stderr "$assay" builtin osv-scanner --base HEAD uv.lock pnpm-lock.yaml
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	holds "$OSV_STUB_CALLS" uv.lock
}

@test "Python's osv-scanner check gets the base from assay check: it fails on the change, passes on the base" {
	upstream
	builtin_checks python
	config_set '.checks |= {"osv-scanner"}'
	echo '[project]' >pyproject.toml
	lock uv.lock 'urllib3 2.2.1 GHSA-1'
	run --separate-stderr "$assay" check
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *$'\nuv.lock: urllib3 2.2.1 (PyPI): GHSA-1: GHSA-1\'s summary; fixed in 2.2.1.1\n'* ]]
	git add uv.lock
	git commit --quiet -m lock
	git push --quiet origin main
	run --separate-stderr "$assay" check
	[ "$status" -eq 0 ]
}

@test "osv-scanner failing is exit 2 with its message; without it, exit 127" {
	local_repo
	lock uv.lock 'idna 3.7'
	run --separate-stderr env OSV_STUB_FAIL=1 "$assay" builtin osv-scanner --base HEAD uv.lock
	[ "$status" -eq 2 ]
	[ "${stderr_lines[0]}" = "failed to query the OSV API: the network is unreachable" ]
	[ "${stderr_lines[1]}" = "assay: osv-scanner failed (exit 127)" ]
	local path
	path=$(path_without osv-scanner)
	run -127 --separate-stderr env PATH="$path" "$assay" builtin osv-scanner --base HEAD uv.lock
	[ "$stderr" = "assay: cannot find osv-scanner on the PATH" ]
}

@test "osv-scanner takes lockfiles from the repo root, and --base" {
	local_repo
	run --separate-stderr "$assay" builtin osv-scanner --base HEAD
	[ "$status" -eq 2 ]
	[ "${stderr_lines[0]}" = "assay: osv-scanner needs the lockfiles to scan" ]
	run --separate-stderr "$assay" builtin osv-scanner --base HEAD /etc/uv.lock
	[ "$status" -eq 2 ]
	[ "${stderr_lines[0]}" = "assay: osv-scanner: a lockfile is a path from the repo root, not '/etc/uv.lock'" ]
	run --separate-stderr "$assay" builtin osv-scanner --fast uv.lock
	[ "$status" -eq 2 ]
	[ "${stderr_lines[0]}" = "assay: osv-scanner: unknown option '--fast'" ]
	run --separate-stderr "$assay" builtin osv-scanner --base= uv.lock
	[ "$status" -eq 2 ]
	[ "${stderr_lines[0]}" = "assay: --base needs a revision" ]
	run --separate-stderr "$assay" builtin osv-scanner uv.lock --base
	[ "$status" -eq 2 ]
	lock uv.lock 'urllib3 2.2.1 GHSA-1'
	run --separate-stderr "$assay" builtin osv-scanner uv.lock --base=HEAD pnpm-lock.yaml
	[ "$status" -eq 1 ]
}
