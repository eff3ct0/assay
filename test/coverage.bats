bats_require_minimum_version 1.5.0
load helpers

# Coverage of new code: a check declares the report it writes (`coverage`); when the check passes, assay measures
# the change's new lines against it with diff-cover.

# lcov <file> <source> <line>:<hits>...: write an LCOV report for one source file.
lcov() {
  local out=$1 src=$2 l
  shift 2
  {
    echo "SF:$src"
    for l in "$@"; do echo "DA:${l%%:*},${l#*:}"; done
    echo end_of_record
  } >"$out"
}

# writes <report> <path>: a check's exec that copies a report prepared by the test to the path it declares.
writes() { echo "mkdir -p \"\$(dirname \"$2\")\" && cp '$1' \"$2\""; }

@test "a passing check whose report covers the new lines passes, and its line counts them" {
  local_repo
  printf 'one\ntwo\n' >lib.sh
  lcov "$T/report" lib.sh 1:3 2:1
  check test "$(writes "$T/report" coverage/lcov.info)" --coverage coverage/lcov.info
  run --separate-stderr "$assay" check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ ${lines[1]} =~ ^ok\ \ \ test\ [0-9]+\.[0-9]{2}s\ \(new\ code:\ 2\ of\ 2\ lines\ covered\)$ ]]
}

@test "under the threshold the check fails, showing diff-cover's report instead of its output" {
  local_repo
  printf 'one\ntwo\nthree\nfour\nfive\n' >lib.sh
  lcov "$T/report" lib.sh 1:1 2:1 3:1 4:1 5:0
  new_code 81
  check test "echo tests passed; $(writes "$T/report" coverage/lcov.info)" --coverage coverage/lcov.info
  run --separate-stderr "$assay" check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ ${lines[1]} =~ ^FAIL\ test\ [0-9.]+s\ \(new\ code:\ 4\ of\ 5\ lines\ covered,\ 80%,\ under\ 81%\)$ ]]
  [ "${lines[2]}" = "--- FAIL test (new code: 4 of 5 lines covered, 80%, under 81%)" ]
  [[ ${lines[3]} == "\$ echo tests passed; "* ]]
  [ "${lines[4]}" = "\$ diff-cover $PWD/coverage/lcov.info --compare-branch=$(sha HEAD) --diff-range-notation=.. --include-untracked" ]
  [[ $output == *"lib.sh (80.0%): Missing lines 5"* ]]
  [[ $output != *"tests passed"$'\n'* ]]
  [[ $output == *$'\nlog: '"$PWD/.git/assay/test.log"$'\n'* ]]
  [[ ${lines[-1]} == "1 of 1 check failed in "*"; rerun: assay check test" ]]
  # The log holds the check's output, then diff-cover's.
  [ "$(head -n 1 .git/assay/test.log)" = "tests passed" ]
  grep -q 'Missing lines 5' .git/assay/test.log
}

@test "at the threshold exactly the check passes" {
  local_repo
  printf 'one\ntwo\nthree\nfour\nfive\n' >lib.sh
  lcov "$T/report" lib.sh 1:1 2:1 3:1 4:1 5:0
  check test "$(writes "$T/report" coverage/lcov.info)" --coverage coverage/lcov.info
  run --separate-stderr "$assay" check
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == *"(new code: 4 of 5 lines covered)" ]]
}

@test "a failing check is not measured" {
  local_repo
  printf 'one\n' >lib.sh
  lcov "$T/report" lib.sh 1:0
  check test "$(writes "$T/report" coverage/lcov.info); echo tests failed; exit 3" --coverage coverage/lcov.info
  run --separate-stderr "$assay" check
  [ "$status" -eq 1 ]
  [[ ${lines[1]} =~ ^FAIL\ test\ [0-9.]+s\ \(exit\ 3\)$ ]]
  [ "${lines[2]}" = "--- FAIL test (exit 3)" ]
  [[ $output != *diff-cover* ]]
}

@test "a passing check that writes no report fails; a report left by an earlier run never counts" {
  local_repo
  printf 'one\n' >lib.sh
  lcov "$T/report" lib.sh 1:1
  check test "$(writes "$T/report" coverage/lcov.info)" --coverage coverage/lcov.info
  "$assay" check >/dev/null
  [ -f coverage/lcov.info ]
  check test "echo no report" --coverage coverage/lcov.info
  run --separate-stderr "$assay" check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ ${lines[1]} =~ ^FAIL\ test\ [0-9.]+s\ \(no\ coverage\ report\ at\ $PWD/coverage/lcov.info\)$ ]]
  [ "${lines[3]}" = "\$ echo no report" ]
  [ "${lines[4]}" = "no report" ]
  [ ! -e coverage/lcov.info ]
}

@test "ASSAY_DIR is assay's directory in the git directory, for every check, and coverage paths can name it" {
  local_repo
  printf 'one\n' >lib.sh
  lcov "$T/report" lib.sh 1:1
  check where "echo \"\$ASSAY_DIR\" >$T/dir"
  check test "$(writes "$T/report" '$ASSAY_DIR/test/lcov.info')" --coverage '$ASSAY_DIR/test/lcov.info'
  check braces "$(writes "$T/report" '$ASSAY_DIR/braces.info')" --coverage '${ASSAY_DIR}/braces.info'
  git worktree add --quiet "$T/wt" -b topic
  cd "$T/wt"
  printf 'one\n' >lib.sh
  run --separate-stderr "$assay" check
  echo "$output"
  [ "$status" -eq 0 ]
  dir=$(git rev-parse --absolute-git-dir)/assay
  [ "$(cat "$T/dir")" = "$dir" ]
  [ -f "$dir/test/lcov.info" ]
  [[ ${lines[2]} == "ok   test "*"(new code: 1 of 1 lines covered)" ]]
  [[ ${lines[1]} == "ok   braces "*"(new code: 1 of 1 lines covered)" ]]
}

@test "new code is the base's tree against the working tree: commits since the base, staged, unstaged, untracked" {
  upstream
  printf 'old\n' >old.sh
  git add old.sh
  git commit --quiet -m old
  git push --quiet origin main
  git checkout --quiet -b topic
  printf 'old\ncommitted\n' >old.sh
  git commit --quiet -am committed
  printf 'staged\n' >staged.sh
  git add staged.sh
  printf 'untracked\n' >untracked.sh
  lcov "$T/a" old.sh 1:0 2:1
  lcov "$T/b" staged.sh 1:1
  lcov "$T/c" untracked.sh 1:0
  cat "$T/a" "$T/b" "$T/c" >"$T/report"
  check test "$(writes "$T/report" lcov.info)" --coverage lcov.info
  run --separate-stderr "$assay" check
  echo "$output"
  # old.sh's first line, uncovered, is the base's: 2 of the 3 new lines are covered.
  [ "$status" -eq 1 ]
  [[ ${lines[1]} == "FAIL test "*"(new code: 2 of 3 lines covered, 66%, under 80%)" ]]
  [[ $output == *"untracked.sh (0.0%): Missing lines 1"* ]]
}

@test "a new file the report does not list counts neither as covered nor as uncovered" {
  local_repo
  printf 'one\n' >lib.sh
  printf 'x = 1\ny = 2\n' >other.py
  lcov "$T/report" lib.sh 1:1
  check test "$(writes "$T/report" lcov.info)" --coverage lcov.info
  run --separate-stderr "$assay" check
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == *"(new code: 1 of 1 lines covered)" ]]
}

@test "a Cobertura report is read too" {
  local_repo
  printf 'one\ntwo\n' >lib.sh
  cat >"$T/report" <<XML
<?xml version="1.0" ?>
<coverage line-rate="0.5" version="1.9">
  <sources><source>$PWD/</source></sources>
  <packages><package name="p"><classes>
    <class name="lib" filename="lib.sh"><lines><line number="1" hits="1"/><line number="2" hits="0"/></lines></class>
  </classes></package></packages>
</coverage>
XML
  check test "$(writes "$T/report" cobertura.xml)" --coverage cobertura.xml
  run --separate-stderr "$assay" check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ ${lines[1]} == "FAIL test "*"(new code: 1 of 2 lines covered, 50%, under 80%)" ]]
}

@test "a change with no line the report can cover passes" {
  local_repo
  check test "$(writes /dev/null lcov.info)" --coverage lcov.info
  run --separate-stderr "$assay" check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == *"(new code: no lines to cover)" ]]
}

@test "without diff-cover on the PATH the check fails" {
  local_repo
  printf 'one\n' >lib.sh
  lcov "$T/report" lib.sh 1:1
  check test "$(writes "$T/report" lcov.info)" --coverage lcov.info
  mkdir "$T/bin"
  for t in bash git jq cp mkdir dirname head tail wc rm cat; do ln -s "$(command -v "$t")" "$T/bin/$t"; done
  PATH=$T/bin run --separate-stderr "$assay" check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ ${lines[1]} == "FAIL test "*"(diff-cover not found)" ]]
}

@test "the coverage settings are validated with the rest of the configuration" {
  local_repo
  check test true --coverage ""
  run --separate-stderr "$assay" check
  [ "$status" -eq 2 ]
  [[ $stderr == *"check test: coverage must be null or a non-empty string"* ]]
  no_checks
  new_code 101
  run --separate-stderr "$assay" check
  [ "$status" -eq 2 ]
  [[ $stderr == *"coverage.newCode must be an integer from 0 to 100"* ]]
  jq 'del(.coverage)' "$ASSAY_CONFIG" >"$T/c" && mv "$T/c" "$ASSAY_CONFIG"
  run --separate-stderr "$assay" check
  [ "$status" -eq 2 ]
}

@test "a lower threshold and a default check's dropped coverage are loosenings, listed with their reasons" {
  local_repo
  check bats true
  jq '.loosenings += [{kind: "new-code", newCode: 50, default: 80, reason: "legacy scripts"},
    {check: "bats", kind: "coverage", reason: "kcov cannot trace it"}]' "$ASSAY_CONFIG" >"$T/c"
  mv "$T/c" "$ASSAY_CONFIG"
  new_code 50
  run --separate-stderr "$assay" check
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "  loosening: new code needs 50% coverage, not assay's 80%: legacy scripts" ]
  [ "${lines[2]}" = "  loosening: bats measures no coverage of new code: kcov cannot trace it" ]
  check bats true --coverage other.xml
  run --separate-stderr "$assay" check
  [ "${lines[2]}" = "  loosening: bats reads another coverage report, other.xml: kcov cannot trace it" ]
  jq '.loosenings += [{kind: "new-code", newCode: 50, default: 80}]' "$ASSAY_CONFIG" >"$T/c"
  mv "$T/c" "$ASSAY_CONFIG"
  run --separate-stderr "$assay" check
  [ "$status" -eq 2 ]
  [[ $stderr == *"loosening of new code has no reason"* ]]
}
