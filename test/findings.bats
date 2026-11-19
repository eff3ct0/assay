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

@test "--sarif prints one SARIF log with two runs, lint and smells, each result new or unchanged; exit 0" {
  local_repo
  builtin_checks plain
  fixture tangled.py src/app.py
  git add src
  git commit --quiet -m tangled
  fixture summarize.py src/report.py
  run --separate-stderr "$assay" findings --base HEAD --sarif
  echo "$stderr"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' <<<"$output")" = 2.1.0 ]
  [ "$(jq '.runs | length' <<<"$output")" -eq 2 ]
  [ "$(jq -c '.runs[0].results' <<<"$output")" = '[]' ]
  [ "$(jq -c '[.runs[1].results[] | select(.ruleId == "qlty:function-complexity")
    | [.locations[0].physicalLocation.artifactLocation.uri, .baselineState]]' <<<"$output")" = '[]' ]
  fixture tangled.py src/more.py
  run --separate-stderr "$assay" findings --base HEAD --sarif
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.runs[1].results[] | select(.ruleId == "qlty:function-complexity")
    | [.locations[0].physicalLocation.artifactLocation.uri, .baselineState]]' <<<"$output")" = '[["src/more.py","new"]]' ]
  [ "$(jq -c '[.runs[1].results[] | select(.ruleId == "qlty:identical-code") | .baselineState]' <<<"$output")" = \
    '["new"]' ]
}

@test "smells for TypeScript, Rust, Python and Scala only: not JavaScript or Go" {
  local_repo
  builtin_checks plain
  for f in tangled.ts tangled.rs tangled.scala tangled.py tangled.js tangled.go; do fixture "$f" "src/$f"; done
  run --separate-stderr "$assay" findings
  echo "$output$stderr"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'qlty/function-complexity' <<<"$output")" -eq 4 ]
  for f in tangled.ts tangled.rs tangled.scala tangled.py; do grep -q "^src/$f:[0-9]*: qlty/function-complexity: " <<<"$output"; done
  [[ $output != *tangled.js* && $output != *tangled.go* ]]
}

@test "the smells' thresholds and switches come from the configuration" {
  local_repo
  builtin_checks plain
  jq '.findings.smells.function_complexity.threshold = 30 | .findings.smells.nested_control_flow.enable = false' \
    "$ASSAY_CONFIG" >"$T/config.json"
  export ASSAY_CONFIG=$T/config.json
  fixture tangled.py src/app.py
  run --separate-stderr "$assay" findings
  echo "$output$stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "no findings on the change" ]
  grep -qx 'threshold = 30' .qlty/qlty.toml
  jq '.findings.smells.function_complexity.threshold = 20' "$T/config.json" >"$T/config2.json"
  ASSAY_CONFIG=$T/config2.json run --separate-stderr "$assay" findings
  [ "${lines[0]}" = "src/app.py:1: qlty/function-complexity: Function with high complexity (count = 27): tangled" ]
}

@test "radarlint for Python: a finding on new code fails, at any level; S3776 never shows; qlty runs no other linter" {
  local_repo
  builtin_checks python
  printf '%s\n' 'def old(x):' '    y = 3' '    return x' >src_old.py
  git add src_old.py
  git commit --quiet -m old
  echo 'LIMIT = 1' >>src_old.py
  fixture tangled.py src/app.py
  printf '%s\n' '' '' 'def fresh(z):' '    w = 2' '    return z' >>src/app.py
  mkdir scripts
  printf '%s\n' '#!/usr/bin/env bash' 'echo $FOO' >scripts/run.sh
  run --separate-stderr "$assay" findings --base HEAD
  echo "$output$stderr"
  [ "$status" -eq 0 ]
  # Lint first, then smells, in each file; the old unused variable is on no changed line.
  [ "${lines[0]}" = 'src/app.py:23: radarlint-python/python:S1481: Remove the unused local variable "w".' ]
  [ "${lines[1]}" = "src/app.py:1: qlty/function-complexity: Function with high complexity (count = 27): tangled" ]
  [ "${lines[-1]}" = "3 findings on the change, 3 of them new: the findings check fails on those" ]
  [[ $output != *S3776* && $output != *src_old.py* && $output != *shellcheck* && $output != *run.sh* ]]
  run --separate-stderr "$assay" findings --base HEAD --sarif
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.runs[0].results[] | [.ruleId, .baselineState]]' <<<"$output")" = \
    '[["radarlint-python:python:S1481","new"]]' ]
  [[ $output != *S3776* ]]
  run --separate-stderr "$assay" check --base HEAD findings
  echo "$output$stderr"
  [ "$status" -eq 1 ]
  [[ $output == *$'\nsrc/app.py:23: radarlint-python/python:S1481: Remove the unused local variable "w".\n'* ]]
  # radarlint is the only plugin, run from the PATH: qlty downloaded nothing, its tools cache holds a lock at most.
  [ "$(grep '^name = ' .qlty/qlty.toml)" = 'name = "radarlint-python"' ]
  grep -q "^script = \"'$(readlink -f "$(command -v radarlint)")' python \${target}\"$" .qlty/qlty.toml
  [ -z "$(find "$HOME/.qlty/cache/tools" -type f ! -name '*.lock' 2>/dev/null)" ]
  [ "$(cat .qlty/configs/radarlint.properties)" = "$(printf '%s\n' radarlint.rules.python.S3776=false radarlint.rules.scala.S3776=false)" ]
}

# without <tool>...: the PATH, less those tools: a new directory of links to everything else on it, first one first.
without() {
  local d f name bin
  bin=$(mktemp -d "$T/without.XXXXXX")
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    for f in "$d"/*; do
      name=${f##*/}
      if [ -x "$f" ] && [ ! -e "$bin/$name" ] && [[ " $* " != *" $name "* ]]; then ln -s "$f" "$bin/$name"; fi
    done
  done
  PATH=$bin
}

@test "without qlty, or radarlint when the configuration runs it: assay findings exits 2, the findings check 127" {
  local_repo
  builtin_checks python
  local path=$PATH
  without qlty
  run --separate-stderr "$assay" findings
  [ "$status" -eq 2 ]
  [ "$stderr" = "assay: cannot find qlty on the PATH" ]
  run -127 --separate-stderr "$assay" builtin findings
  [ "$stderr" = "assay: cannot find qlty on the PATH" ]
  run --separate-stderr "$assay" check findings
  [ "$status" -eq 1 ]
  [[ ${lines[1]} == "FAIL findings "*" (exit 127: tool not found)" ]]
  PATH=$path
  without radarlint
  run -127 --separate-stderr "$assay" builtin findings
  [ "$stderr" = "assay: cannot find radarlint on the PATH, which the findings run for python" ]
}

@test "qlty failing is exit 2 with its message, never a pass or a finding" {
  local_repo
  builtin_checks plain
  mkdir "$T/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "qlty broke" >&2' 'exit 99' >"$T/bin/qlty"
  chmod +x "$T/bin/qlty"
  PATH=$T/bin:$PATH
  run --separate-stderr "$assay" findings
  [ "$status" -eq 2 ]
  [ "${stderr_lines[0]}" = "qlty broke" ]
  [ "${stderr_lines[-1]}" = "assay: qlty check failed (exit 99)" ]
  run --separate-stderr "$assay" builtin findings
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "a repo that tracks .qlty/qlty.toml is exit 2, the file left as it was" {
  local_repo
  builtin_checks plain
  mkdir .qlty
  echo 'config_version = "0"' >.qlty/qlty.toml
  git add .qlty
  git commit --quiet -m qlty
  run --separate-stderr "$assay" findings
  [ "$status" -eq 2 ]
  [[ $stderr == "assay: the repo tracks .qlty/qlty.toml, which assay writes on every run from assay.findings:"* ]]
  [ "$(cat .qlty/qlty.toml)" = 'config_version = "0"' ]
  [ -z "$(git status --porcelain)" ]
}

@test "the findings check's base is assay check's: --base, else ASSAY_BASE, else the fork point" {
  upstream
  builtin_checks plain
  fixture tangled.py src/app.py
  git add src
  git commit --quiet -m tangled
  run --separate-stderr "$assay" check findings
  [ "$status" -eq 1 ]
  [[ $output == *"src/app.py:1: qlty/function-complexity: "* ]]
  ASSAY_BASE=HEAD run --separate-stderr "$assay" check findings
  [ "$status" -eq 0 ]
  ASSAY_BASE=HEAD run --separate-stderr "$assay" findings --base HEAD~1
  [ "${lines[0]}" = "src/app.py:1: qlty/function-complexity: Function with high complexity (count = 27): tangled" ]
}
