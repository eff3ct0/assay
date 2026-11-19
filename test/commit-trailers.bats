bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

# commit-trailers: no commit in base..HEAD carries a Co-Authored-By trailer, matched case-insensitively.

# commit <subject> [<paragraph>...]: an empty commit with that message.
commit() {
	local -a args=()
	local p
	for p in "$@"; do args+=(-m "$p"); done
	git commit --quiet --allow-empty "${args[@]}"
}

@test "a Co-Authored-By trailer in any case, in a commit after the base, fails naming each commit" {
	local_repo
	base=$(sha HEAD)
	commit "one" "Body." "co-authored-by: A <a@example.com>"
	commit "two"
	commit "three" "Body." "Signed-off-by: T <t@example.com>" "  CO-AUTHORED-BY : B <b@example.com>"
	run --separate-stderr "$assay" builtin commit-trailers --base "$base"
	[ "$status" -eq 1 ]
	expected="Co-Authored-By trailers in $(short "$base")..HEAD:
  $(short HEAD) three
      CO-AUTHORED-BY : B <b@example.com>
  $(short HEAD~2) one
      co-authored-by: A <a@example.com>
A commit names no co-author: reword each of these without its trailer (git rebase -i $(short "$base")), and push with --force-with-lease where they were pushed."
	diff <(echo "$expected") <(echo "$output")
}

@test "a trailer only in commits before the base passes" {
	local_repo
	commit "old" "Co-Authored-By: A <a@example.com>"
	base=$(sha HEAD)
	commit "new" "Body."
	run --separate-stderr "$assay" builtin commit-trailers --base "$base"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "a mention that does not start a line passes" {
	local_repo
	base=$(sha HEAD)
	commit "drop the trailer" "This commit adds no Co-Authored-By: trailer."
	run --separate-stderr "$assay" builtin commit-trailers --base "$base"
	[ "$status" -eq 0 ]
}

@test "a merge commit in base..HEAD is checked too" {
	local_repo
	base=$(sha HEAD)
	git switch --quiet -c side
	commit "side"
	git switch --quiet main
	commit "main"
	git merge --quiet --no-ff side -m "merge side" -m "Co-authored-by: A <a@example.com>"
	run --separate-stderr "$assay" builtin commit-trailers --base "$base"
	[ "$status" -eq 1 ]
	[[ $output == *"$(short HEAD) merge side"* ]]
}

@test "the base comes from ASSAY_BASE, as assay check exports it" {
	upstream
	commit "local" "Co-authored-by: A <a@example.com>"
	check commit-trailers "\"$assay\" builtin commit-trailers"
	run "$assay" check
	[ "$status" -eq 1 ]
	[[ $output == *"Co-Authored-By trailers in $(short origin/main)..HEAD:"* ]]
	run "$assay" check --base HEAD
	[ "$status" -eq 0 ]
}
