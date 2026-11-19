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

@test "a smell present at the base in a touched file is shown but is not new, even grown: the findings check passes" {
  local_repo
  builtin_checks plain
  fixture tangled.py src/app.py
  git add src
  git commit --quiet -m tangled
  # The function grows a branch at its top level, and the file a simple function.
  sed -i '18a\        elif i % 11 == 0:\n            total += 3' src/app.py
  printf '%s\n' '' '' 'def simple(a):' '    return a + 1' >>src/app.py
  run --separate-stderr "$assay" findings --base HEAD
  echo "$output$stderr"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "src/app.py:1: qlty/function-complexity: Function with high complexity (count = 28): tangled (at the base too)" ]
  [ "${lines[1]}" = "src/app.py:7: qlty/nested-control-flow: Deeply nested control flow (level = 5) (not on new code)" ]
  [ "${lines[-1]}" = "2 findings on the change, none new: the findings check passes" ]
  run --separate-stderr "$assay" check --base HEAD findings
  echo "$output$stderr"
  [ "$status" -eq 0 ]
}

@test "a new clone is a new finding naming both places; a clone the base has is not, in a touched file" {
  local_repo
  builtin_checks plain
  fixture summarize.py src/report.py
  git add src
  git commit --quiet -m report
  fixture summarize.py src/export.py
  run --separate-stderr "$assay" findings --base HEAD
  echo "$output$stderr"
  [ "$status" -eq 0 ]
  [[ ${lines[0]} =~ ^src/export\.py:1:\ qlty/identical-code:\ Found\ 21\ lines\ of\ identical\ code\ in\ 2\ locations\ \(mass\ =\ [0-9]+\):\ src/export\.py:1-21,\ src/report\.py:1-21$ ]]
  [ "${lines[-1]}" = "1 finding on the change, 1 of them new: the findings check fails on those" ]
  run --separate-stderr "$assay" check --base HEAD findings
  echo "$output$stderr"
  [ "$status" -eq 1 ]
  [[ $output == *"src/export.py:1: qlty/identical-code: "*": src/export.py:1-21, src/report.py:1-21"* ]]
  git add src
  git commit --quiet -m export
  printf '%s\n' '' '' 'LIMIT = 3' >>src/export.py
  run --separate-stderr "$assay" findings --base HEAD
  echo "$output$stderr"
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "src/export.py:1: qlty/identical-code: "*" (at the base too)" ]]
  run --separate-stderr "$assay" check --base HEAD findings
  [ "$status" -eq 0 ]
}

@test "a renamed file keeps its smells' counterparts; paths come out as they are, spaces and non-ASCII included" {
  local_repo
  builtin_checks plain
  fixture tangled.py src/app.py
  git add src
  git commit --quiet -m tangled
  mkdir 'src/my dir'
  git mv src/app.py 'src/my dir/é#1.py'
  run --separate-stderr "$assay" findings --base HEAD
  echo "$output$stderr"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "src/my dir/é#1.py:1: qlty/function-complexity: Function with high complexity (count = 27): tangled (at the base too)" ]
  [ "${lines[1]}" = "src/my dir/é#1.py:7: qlty/nested-control-flow: Deeply nested control flow (level = 5) (not on new code)" ]
  run --separate-stderr "$assay" check --base HEAD findings
  [ "$status" -eq 0 ]
  # A copy is no rename: its smells are new.
  cp 'src/my dir/é#1.py' 'src/my dir/ü.py'
  run --separate-stderr "$assay" check --base HEAD findings
  echo "$output$stderr"
  [ "$status" -eq 1 ]
  [[ $output == *$'\nsrc/my dir/ü.py:1: qlty/function-complexity: '* ]]
}
