bats_require_minimum_version 1.5.0
load helpers

# `assay findings`: the analyzer's findings on the change, from qlty run in the repo itself, and the built-in
# `findings` check, which fails on the new ones among them. qlty and radarlint come from the PATH, as the devenv gives
# them.

@test "assay findings writes .qlty/ on every run, out of git through .git/info/exclude" {
  local_repo
  run --separate-stderr "$assay" findings
  echo "$output$stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "no findings on the change" ]
  [ -f .qlty/qlty.toml ]
  grep -qx '.qlty/' .git/info/exclude
  [ -z "$(git status --porcelain --untracked-files=all)" ]
  # Written again on the next run, and listed once.
  echo stale >.qlty/qlty.toml
  run --separate-stderr "$assay" findings
  [ "$status" -eq 0 ]
  [ "$(cat .qlty/qlty.toml)" != stale ]
  [ "$(grep -cx '.qlty/' .git/info/exclude)" -eq 1 ]
}

# fixture <name> [<path>]: copy test/fixtures/findings/<name> into the repo, at <path> (default: <name>).
fixture() {
  local to=${2:-$1}
  mkdir -p "$(dirname "$to")"
  cp "$BATS_TEST_DIRNAME/fixtures/findings/$1" "$to"
}

@test "a new function over the complexity threshold is a new finding: shown, and the findings check fails" {
  local_repo
  builtin_checks plain
  fixture tangled.py src/app.py
  run --separate-stderr "$assay" findings
  echo "$output$stderr"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "src/app.py:1: qlty/function-complexity: Function with high complexity (count = 27): tangled" ]
  [ "${lines[1]}" = "src/app.py:7: qlty/nested-control-flow: Deeply nested control flow (level = 5)" ]
  [ "${lines[-1]}" = "2 findings on the change, 2 of them new: the findings check fails on those" ]
  run --separate-stderr "$assay" check findings
  echo "$output$stderr"
  [ "$status" -eq 1 ]
  [[ $output == *$'\nsrc/app.py:1: qlty/function-complexity: Function with high complexity (count = 27): tangled\n'* ]]
  [[ $output == *$'\n2 new findings on the change: fix each one (assay findings shows them among the rest)\n'* ]]
}
