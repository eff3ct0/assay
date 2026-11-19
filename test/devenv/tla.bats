# shellcheck disable=SC2016 # the model's TLA+ text, and the devenv's own $DEVENV_PROFILE, are literal
bats_require_minimum_version 1.5.0
# shellcheck source=test/devenv/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# The tla check through the real devenv: off by default, with no TLC in the devenv, and turned on in a repo's
# devenv.nix, which brings TLC (tlaplus18).

# clock <bounded|unbounded>: tla/Clock.tla and tla/Clock.cfg, a clock whose hour stays in 1..12 when it wraps around.
clock() {
	mkdir -p tla
	local next='hour'"'"' = IF hour = 12 THEN 1 ELSE hour + 1'
	if [ "$1" = unbounded ]; then next='hour'"'"' = hour + 1'; fi
	printf '%s\n' '---- MODULE Clock ----' 'EXTENDS Naturals' 'VARIABLE hour' 'Init == hour = 1' "Next == $next" \
		'Spec == Init /\ [][Next]_hour' 'InRange == hour \in 1..12' '====' >tla/Clock.tla
	printf '%s\n' 'SPECIFICATION Spec' 'INVARIANT InRange' >tla/Clock.cfg
}

# trace <log>: a violation's trace in TLC's output, from its error to the count of states.
trace() { sed -n '/^Error: /,/ states generated, /p' "$1"; }

@test "tla: off and listed so, without TLC; on, it brings TLC, skips a repo with no model, passes a correct one and fails a broken one with the same trace" {
	consumer
	shape
	run --separate-stderr devenv shell -- assay check --list
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "tla (off)" ]
	# TLC, whichever the caller's PATH holds, is not in the devenv's profile.
	run devenv shell -- bash -c 'test -e "$DEVENV_PROFILE/bin/tlc"'
	[ "$status" -eq 1 ]

	devenv_nix '{ assay.checks.tla.enable = true; }'
	git commit --quiet -am "tla on"
	run --separate-stderr devenv shell -- assay check --list
	[ "${lines[-1]}" = "tla" ]
	run devenv shell -- bash -c 'test -x "$DEVENV_PROFILE/bin/tlc"'
	[ "$status" -eq 0 ]
	run --separate-stderr devenv shell -- assay check tla
	echo "$output"
	[ "$status" -eq 0 ]
	[ "${lines[1]}" = "  skipped: tla (no tla/*.cfg)" ]
	[ "${lines[2]}" = "skip tla (no tla/*.cfg)" ]

	clock bounded
	git add tla
	git commit --quiet -m model
	run --separate-stderr devenv shell -- assay check tla
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[1]} == "ok   tla "* ]]
	prints '' git status --porcelain
	prints "$(printf '%s\n' Clock.cfg Clock.tla)" ls tla

	clock unbounded
	git_dir=$(git rev-parse --absolute-git-dir)
	run --separate-stderr devenv shell -- assay check tla
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *"Error: Invariant InRange is violated."* ]]
	[[ $output == *$'\ntla/Clock.cfg: TLC exit 12\n1 of 1 TLA+ configuration failed\n'* ]]
	trace "$git_dir/assay/tla.log" >"$T/first"
	grep -qxF 'hour = 13' "$T/first"
	run --separate-stderr devenv shell -- assay check tla
	[ "$status" -eq 1 ]
	trace "$git_dir/assay/tla.log" >"$T/second"
	diff "$T/first" "$T/second"
	prints ' M tla/Clock.tla' git status --porcelain
}
