# shellcheck disable=SC2016 # the fixtures' shell text and the messages' backquotes are literal
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# The helpers assay's default checks run (devenv/bin/), against throwaway repos, with the real tools on the PATH.

bin=$BATS_TEST_DIRNAME/../devenv/bin

# listed <command>...: the NUL-terminated entries a command prints, one per line.
listed() {
	"$@" >"$T/listed" || return
	tr '\0' '\n' <"$T/listed"
}

@test "assay-files lists the files git sees that exist, matching git glob pathspecs from the root" {
	local_repo
	mkdir -p sub/deep
	printf '%s\n' ignored.nix >.gitignore
	touch top.nix sub/a.nix sub/deep/b.nix ignored.nix 'with space.nix' gone.nix notes.txt
	git add top.nix sub/a.nix gone.nix .gitignore
	git commit --quiet -m files
	rm gone.nix
	run listed "$bin/assay-files" '**/*.nix'
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' sub/a.nix sub/deep/b.nix top.nix 'with space.nix')" ]
	run listed "$bin/assay-files" '*.nix'
	[ "$output" = "$(printf '%s\n' top.nix 'with space.nix')" ]
	cd sub
	run listed "$bin/assay-files" '*.nix'
	[ "$output" = "$(printf '%s\n' ../top.nix '../with space.nix')" ]
	run listed "$bin/assay-files"
	[[ $output == *"../notes.txt"* ]]
	[[ $output == *"../a.txt"* ]]
	[[ $output != *ignored.nix* ]]
}

@test "assay-files leaves out directories, such as a submodule" {
	local_repo
	git init --quiet "$T/module"
	commit_file "$T/module" inner.nix
	git -c protocol.file.allow=always submodule --quiet add "$T/module" mod
	git commit --quiet -m submodule
	run listed "$bin/assay-files"
	[ "$output" = "$(printf '%s\n' .gitmodules a.txt)" ]
}

@test "assay-nixf-tidy turns nixf-tidy's diagnostics into lines and a failure, and passes a clean file" {
	local_repo
	printf '{ a = 1; }\n' >good.nix
	printf '{\n  x = undefinedThing;\n}\n' >undefined.nix
	printf '{ a = (1 + ; }\n' >broken.nix
	run --separate-stderr "$bin/assay-nixf-tidy" good.nix
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run --separate-stderr "$bin/assay-nixf-tidy" good.nix undefined.nix broken.nix
	echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = 'undefined.nix:2:7: error sema-undefined-variable: undefined variable `undefinedThing`' ]
	[[ ${lines[1]} == "broken.nix:1:"*": error parse-expected: expected "* ]]
	run --separate-stderr "$bin/assay-nixf-tidy"
	[ "$status" -eq 0 ]
}

# hits <cobertura.xml>: each line the report lists, as <file>:<line>:<hits>, the file relative to the current
# directory.
hits() {
	awk -v root="$PWD/" '
    /<source>/ { src = $0; sub(/.*<source>/, "", src); sub(/<\/source>.*/, "", src) }
    /<class / { f = $0; sub(/.*filename="/, "", f); sub(/".*/, "", f); if (f !~ /^\//) f = src f; sub("^" root, "", f) }
    /<line / { n = $0; sub(/.*number="/, "", n); sub(/".*/, "", n); h = $0; sub(/.*hits="/, "", h); sub(/".*/, "", h); print f ":" n ":" h }
  ' "$1" >"$T/hits" || return
	LC_ALL=C sort -t: -k1,1 -k2,2n "$T/hits"
}

# needs_kcov: skip the test where nixpkgs has no kcov (it has it for Linux only).
needs_kcov() {
	if ! command -v kcov >/dev/null; then skip "no kcov on this platform"; fi
}

# bash_project: scripts, tested or not, a test file, and files that are not shell scripts git sees. The test runs the
# tool through bash: the sandbox of `nix flake check` has no /usr/bin/env.
bash_project() {
	mkdir -p lib test
	printf 'greet() {\n\techo "hello $1"\n}\n' >lib/greet.sh
	printf '#!/usr/bin/env bash\nset -eu\necho "tool $1"\n' >tool
	printf '#!/usr/bin/env bash\necho untested\necho twice\n' >untested.sh
	chmod +x tool untested.sh
	# A library kcov does not take for a script: no .sh, no shebang, no "sh" in its first 80 bytes.
	printf 'quiet() {\n\ttrue\n}\n' >lib/quiet.bash
	printf 'x = 1\n' >other.py
	printf '%s\n' ignored.sh >.gitignore
	printf '#!/usr/bin/env bash\necho ignored\n' >ignored.sh
	cat >test/a.bats <<'BATS'
setup() { source "$BATS_TEST_DIRNAME/../lib/greet.sh"; }
@test "greets" { run greet you; [ "$output" = "hello you" ]; }
@test "runs the tool" { run bash "$BATS_TEST_DIRNAME/../tool" x; [ "$output" = "tool x" ]; }
BATS
	git add -A
}

@test "assay-bats runs the tests under kcov; its report lists every script git sees, those no test runs too" {
	needs_kcov
	local_repo
	bash_project
	run --separate-stderr "$bin/assay-bats" .git/assay/kcov
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = 1..2 ]
	[ "${lines[2]}" = "ok 2 runs the tool" ]
	run hits .git/assay/kcov/bats/cobertura.xml
	echo "$output"
	[ "$output" = "$(printf '%s\n' lib/greet.sh:2:1 lib/quiet.bash:2:0 tool:2:1 tool:3:1 untested.sh:2:0 untested.sh:3:0)" ]
}

@test "assay-bats runs the tracked .bats files only" {
	needs_kcov
	local_repo
	bash_project
	printf '@test "untracked" { false; }\n' >test/untracked.bats
	run --separate-stderr "$bin/assay-bats" .git/assay/kcov
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = 1..2 ]
}

@test "assay-bats fails with bats, starts from an empty report, and keeps kcov's trace noise out of its output" {
	needs_kcov
	local_repo
	bash_project
	mkdir -p .git/assay/kcov/bats
	echo stale >.git/assay/kcov/bats/cobertura.xml
	printf '@test "fails" { run printf "a\\nb\\n"; false; }\n' >test/b.bats
	git add test/b.bats
	run --separate-stderr "$bin/assay-bats" .git/assay/kcov
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"not ok 3 fails"* ]]
	[[ $output != *kcov@* ]]
	[ "${lines[-1]}" = "assay-bats: kcov's and bats' standard error: .git/assay/kcov/kcov.stderr" ]
	[ -f .git/assay/kcov/kcov.stderr ]
	grep -q '<coverage' .git/assay/kcov/bats/cobertura.xml
}

@test "assay-bats with no test still writes the report, every script uncovered; with no script, an empty one" {
	needs_kcov
	local_repo
	bash_project
	git rm --quiet --force test/a.bats
	run --separate-stderr "$bin/assay-bats" .git/assay/kcov
	echo "$output"
	[ "$status" -eq 0 ]
	run hits .git/assay/kcov/bats/cobertura.xml
	[ "$output" = "$(printf '%s\n' lib/greet.sh:2:0 lib/quiet.bash:2:0 tool:2:0 tool:3:0 untested.sh:2:0 untested.sh:3:0)" ]
	rm -r lib tool untested.sh
	run --separate-stderr "$bin/assay-bats" .git/assay/kcov
	[ "$status" -eq 0 ]
	run hits .git/assay/kcov/bats/cobertura.xml
	[ -z "$output" ]
	mkdir -p test
	printf '@test "passes" { true; }\n' >test/c.bats
	git add test/c.bats
	run --separate-stderr "$bin/assay-bats" .git/assay/kcov
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "ok 1 passes" ]
	run hits .git/assay/kcov/bats/cobertura.xml
	[ -z "$output" ]
}
