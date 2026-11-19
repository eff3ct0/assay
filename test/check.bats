load helpers

# The run's lines, without the timing.
untimed() { sed -E 's/ [0-9]+\.[0-9]{2}s/ Ns/g' <<<"$output"; }

@test "every selected check runs in name order, without stopping at the first failure" {
  local_repo
  check c "echo c >>$T/ran"
  check a "echo a >>$T/ran"
  check b "echo b >>$T/ran; exit 3"
  run "$assay" check
  [ "$status" -eq 1 ]
  [ "$(cat "$T/ran")" = "$(printf 'a\nb\nc')" ]
  [[ ${lines[1]} =~ ^ok\ \ \ a\ [0-9]+\.[0-9]{2}s$ ]]
  [[ ${lines[2]} =~ ^FAIL\ b\ [0-9]+\.[0-9]{2}s\ \(exit\ 3\)$ ]]
  [[ ${lines[3]} =~ ^ok\ \ \ c\ [0-9]+\.[0-9]{2}s$ ]]
}

@test "the output has the header, a line per check, each failure and a last line with the rerun command" {
  local_repo
  check lint "echo lint says no; exit 1"
  check fmt true --fast
  check test "seq 1 150; exit 2"
  run "$assay" check
  [ "$status" -eq 1 ]
  gitdir=$(git rev-parse --absolute-git-dir)
  expected="assay check · base main@$(short HEAD) (fork-point)
ok   fmt Ns
FAIL lint Ns (exit 1)
FAIL test Ns (exit 2)

--- FAIL lint (exit 1)
\$ echo lint says no; exit 1
lint says no
log: $gitdir/assay/lint.log

--- FAIL test (exit 2)
\$ seq 1 150; exit 2
$(seq 1 100)
[50 more lines in the log]
log: $gitdir/assay/test.log

2 of 3 checks failed in Ns; rerun: assay check lint test"
  diff <(echo "$expected") <(untimed)
}

@test "a passing run ends with the count and exits 0" {
  local_repo
  check a true
  check b true --fast
  run "$assay" check
  [ "$status" -eq 0 ]
  [[ ${lines[-1]} =~ ^2\ checks\ passed\ in\ [0-9]+\.[0-9]{2}s$ ]]
}

@test "a run with nothing selected passes" {
  local_repo
  check slow true
  run "$assay" check --fast
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "no checks to run" ]
}

@test "each failure's full log is <git-dir>/assay/<check>.log, overwritten on each run" {
  local_repo
  check noisy "echo run \$(cat $T/n 2>/dev/null); exit 1"
  echo 1 >"$T/n"
  "$assay" check || true
  echo 2 >"$T/n"
  run "$assay" check
  [ "$(cat .git/assay/noisy.log)" = "run 2" ]
  [ -z "$(git status --porcelain)" ]
}

@test "the log lives in the worktree's own git directory" {
  local_repo
  check fails false
  git worktree add --quiet "$T/wt" -b topic
  cd "$T/wt"
  run "$assay" check
  [ "$status" -eq 1 ]
  log=$(git rev-parse --absolute-git-dir)/assay/fails.log
  [ "$log" != "$T/work/.git/assay/fails.log" ]
  [ -f "$log" ]
  [[ $output == *"log: $log"* ]]
}

@test "a check's output is shown whole when it has no final newline" {
  local_repo
  check bare "printf 'no newline'; exit 1"
  run "$assay" check
  [[ $output == *$'no newline\nlog: '* ]]
}

@test "a check with no output says so" {
  local_repo
  check quiet false
  run "$assay" check
  [[ $output == *$'$ false\n(no output)\nlog: '* ]]
}

@test "a missing tool fails its check with exit 127" {
  local_repo
  check tool "no-such-tool --version"
  run "$assay" check
  [ "$status" -eq 1 ]
  [[ ${lines[1]} =~ ^FAIL\ tool\ [0-9.]+s\ \(exit\ 127:\ tool\ not\ found\)$ ]]
}

@test "--fast runs only the fast checks" {
  local_repo
  check quick "echo quick >>$T/ran" --fast
  check slow "echo slow >>$T/ran"
  run "$assay" check --fast
  [ "$status" -eq 0 ]
  [ "$(cat "$T/ran")" = quick ]
  [[ ${lines[0]} == "assay check --fast · base "* ]]
}

@test "without --fast every enabled check runs, the fast ones included" {
  local_repo
  check quick "echo quick >>$T/ran" --fast
  check slow "echo slow >>$T/ran"
  check off "echo off >>$T/ran" --off
  run "$assay" check
  [ "$status" -eq 0 ]
  [ "$(cat "$T/ran")" = "$(printf 'quick\nslow')" ]
}

@test "going over the fast set's budget fails nothing" {
  local_repo
  check slow-but-fast "sleep 5.1" --fast
  run "$assay" check --fast
  [ "$status" -eq 0 ]
  [[ ${lines[-1]} == *"(over the fast set's 5s budget)" ]]
}

@test "names select checks, run in name order" {
  local_repo
  check a "echo a >>$T/ran"
  check b "echo b >>$T/ran"
  check c "echo c >>$T/ran"
  run "$assay" check c a c
  [ "$status" -eq 0 ]
  [ "$(cat "$T/ran")" = "$(printf 'a\nc')" ]
  [[ ${lines[0]} == "assay check a c · base "* ]]
}

@test "--fast with names runs the named fast checks" {
  local_repo
  check a "echo a >>$T/ran" --fast
  check b "echo b >>$T/ran" --fast
  run "$assay" check --fast b
  [ "$status" -eq 0 ]
  [ "$(cat "$T/ran")" = b ]
}

@test "naming an unknown, disabled or (with --fast) slow check exits 2" {
  local_repo
  check slow true
  check off true --off
  for args in "nope" "off" "--fast slow" "../x"; do
    # shellcheck disable=SC2086
    run "$assay" check $args
    [ "$status" -eq 2 ]
    [[ ${lines[0]} == "assay: "* ]]
  done
}

@test "the rerun command keeps --base" {
  upstream
  check fails false
  run "$assay" check --base "HEAD~1"
  [ "$status" -eq 1 ]
  [ "${lines[-1]##*; }" = "rerun: assay check --base 'HEAD~1' fails" ]
}

@test "--list prints the enabled checks in name order, fast ones marked, and exits 0" {
  check zeta true
  check alpha true --fast
  check off true --off
  cd "$T"
  run "$assay" check --list
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'alpha (fast)\nzeta')" ]
}

@test "--list takes no other argument" {
  run "$assay" check --list --fast
  [ "$status" -eq 2 ]
  run "$assay" check --list a
  [ "$status" -eq 2 ]
}

@test "a check runs from the repo root with ASSAY_BASE set to the base's full sha" {
  upstream
  mkdir sub
  check where "pwd >$T/pwd; echo \"\$ASSAY_BASE\" >$T/base"
  cd sub
  run "$assay" check
  [ "$status" -eq 0 ]
  [ "$(cat "$T/pwd")" = "$(cd "$T/work" && pwd -P)" ]
  [ "$(cat "$T/base")" = "$(sha origin/main)" ]
}

@test "checks run with the caller's PATH, not assay's own tools" {
  local_repo
  mkdir "$T/tools"
  printf '#!/bin/sh\necho mine\n' >"$T/tools/only-assay-has-this"
  chmod +x "$T/tools/only-assay-has-this"
  check probe "only-assay-has-this"
  run env assay_tools="$T/tools" "$assay" check
  [ "$status" -eq 1 ]
  [[ ${lines[1]} == "FAIL probe "*"(exit 127: tool not found)" ]]
}

@test "requires: nothing matching skips the check, which passes and is listed in the header" {
  local_repo
  check cargo "echo cargo >>$T/ran" --requires Cargo.toml
  check other true
  run "$assay" check
  [ "$status" -eq 0 ]
  [ ! -e "$T/ran" ]
  [ "${lines[1]}" = "  skipped: cargo (no Cargo.toml)" ]
  [ "${lines[2]}" = "skip cargo (no Cargo.toml)" ]
  [[ ${lines[-1]} =~ ^2\ checks\ passed\ \(1\ skipped\)\ in ]]
}

@test "requires: a tracked or untracked file runs the check, an ignored one does not" {
  local_repo
  check cargo "echo cargo >>$T/ran" --requires Cargo.toml
  echo Cargo.toml >.gitignore
  touch Cargo.toml
  run "$assay" check
  [[ $output == *"skip cargo (no Cargo.toml)"* ]]
  rm .gitignore
  run "$assay" check
  [ "$status" -eq 0 ]
  [ "$(cat "$T/ran")" = cargo ]
  git add Cargo.toml
  git commit --quiet -m cargo
  run "$assay" check
  [ "$(cat "$T/ran")" = "$(printf 'cargo\ncargo')" ]
}

@test "requires: a glob is matched from the repo root, ** crossing directories" {
  local_repo
  check root-only true --requires "*.toml"
  check anywhere true --requires "**/*.toml"
  mkdir -p crates/x
  touch crates/x/Cargo.toml
  cd crates
  run "$assay" check
  [ "$status" -eq 0 ]
  [[ $output == *"skip root-only (no *.toml)"* ]]
  [[ $output == *"ok   anywhere "* ]]
}

@test "loosenings are listed with their reasons in the header" {
  local_repo
  check lint true --off
  check test "make test"
  check fmt true
  loosening lint off "legacy code, see #12"
  loosening test exec "the suite needs a database"
  run "$assay" check fmt
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "  loosening: lint is off: legacy code, see #12" ]
  [ "${lines[2]}" = "  loosening: test runs the repo's own exec: the suite needs a database" ]
}

@test "not in a git working tree exits 2" {
  check a true
  cd "$T"
  run "$assay" check
  [ "$status" -eq 2 ]
  [ "$output" = "assay: not in a git working tree" ]
  local_repo
  cd .git
  run "$assay" check
  [ "$status" -eq 2 ]
}

@test "usage errors exit 2" {
  run "$assay"
  [ "$status" -eq 2 ]
  run "$assay" frobnicate
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "assay: unknown command 'frobnicate'" ]
  run "$assay" check --nope
  [ "$status" -eq 2 ]
  run "$assay" check --base
  [ "$status" -eq 2 ]
  run "$assay" check --base=
  [ "$status" -eq 2 ]
}

@test "--help prints the usage and exits 0" {
  run "$assay" --help
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "usage: assay check "* ]]
  run "$assay" check --help
  [ "$status" -eq 0 ]
}

# Failing closed: whatever goes wrong with the configuration, nothing runs and assay exits 2.

# fails_closed <description>: assay check exits 2 with an `assay:` message, and the check did not run.
fails_closed() {
  run "$assay" check
  echo "$1: $output"
  [ "$status" -eq 2 ]
  [[ ${lines[0]} == "assay: "* ]]
  [ ! -e "$T/ran" ]
}

@test "without ASSAY_CONFIG, in a repo that has not adopted assay, assay exits 2" {
  local_repo
  check a "touch $T/ran"
  outside_devenv
  fails_closed unset
  [[ $output == *"/docs/adoption.md"* ]]
}

@test "an unreadable configuration exits 2" {
  local_repo
  check a "touch $T/ran"
  good=$ASSAY_CONFIG
  export ASSAY_CONFIG=$T/missing.json
  fails_closed missing
  export ASSAY_CONFIG=$T
  fails_closed directory
  export ASSAY_CONFIG=$good
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$ASSAY_CONFIG"
    fails_closed "no read permission"
  fi
}

@test "a malformed configuration exits 2" {
  local_repo
  check a "touch $T/ran"
  good=$(cat "$ASSAY_CONFIG")
  bad() {
    printf '%s' "$2" >"$ASSAY_CONFIG"
    fails_closed "$1"
  }
  bad empty ""
  bad truncated "${good:0:30}"
  bad "two documents" "$good $good"
  bad "not an object" "[$good]"
  bad "no version" "$(jq -c 'del(.version)' <<<"$good")"
  bad "another version" "$(jq -c '.version = 2' <<<"$good")"
  bad "checks not an object" "$(jq -c '.checks = []' <<<"$good")"
  bad "no loosenings" "$(jq -c 'del(.loosenings)' <<<"$good")"
  bad "exec missing" "$(jq -c 'del(.checks.a.exec)' <<<"$good")"
  bad "exec empty" "$(jq -c '.checks.a.exec = ""' <<<"$good")"
  bad "fast not a boolean" "$(jq -c '.checks.a.fast = "yes"' <<<"$good")"
  bad "enable missing" "$(jq -c 'del(.checks.a.enable)' <<<"$good")"
  bad "requires not a string" "$(jq -c '.checks.a.requires = 1' <<<"$good")"
  bad "a name with a slash" "$(jq -c '.checks["a/b"] = .checks.a' <<<"$good")"
  bad "a loosening without a reason" "$(jq -c '.loosenings = [{check: "a", kind: "off"}]' <<<"$good")"
  bad "a loosening of an unknown check" "$(jq -c '.loosenings = [{check: "z", kind: "off", reason: "r"}]' <<<"$good")"
  bad "a loosening of an unknown kind" "$(jq -c '.loosenings = [{check: "a", kind: "x", reason: "r"}]' <<<"$good")"
}

@test "without jq assay exits 2" {
  local_repo
  check a "touch $T/ran"
  mkdir "$T/bin"
  for t in git head tail wc mkdir rm; do ln -s "$(command -v "$t")" "$T/bin/$t"; done
  run env PATH="$T/bin" "$BASH" "$assay" check
  [ "$status" -eq 2 ]
  [ "$output" = "assay: cannot find jq on the PATH" ]
  [ ! -e "$T/ran" ]
}

@test "a log directory that cannot be created exits 2" {
  local_repo
  check a "touch $T/ran"
  touch .git/assay
  run "$assay" check
  [ "$status" -eq 2 ]
  [[ ${lines[0]} == "assay: cannot create "* ]]
  [ ! -e "$T/ran" ]
}

@test "an unexpected failure exits 2, never 1" {
  local_repo
  check fails "echo output; exit 1"
  # A head that fails, as a broken tool would, while assay prints the failure's output.
  mkdir "$T/bin"
  printf '#!/bin/sh\nexit 1\n' >"$T/bin/head"
  chmod +x "$T/bin/head"
  run env PATH="$T/bin:$PATH" "$assay" check
  [ "$status" -eq 2 ]
  [ "${lines[-1]}" = "assay: unexpected failure (exit 1)" ]
}

@test "a loosening of a setting of the analyzer is listed with its reason in the header" {
  local_repo
  check fmt true
  jq '.loosenings += [{check: "findings", kind: "setting", reason: "parsers are one big match",
    what: "smells.function_complexity.threshold is 25, above qlty'"'"'s 18"}]' "$ASSAY_CONFIG" >"$T/c.json"
  mv "$T/c.json" "$ASSAY_CONFIG"
  run "$assay" check fmt
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "  loosening: findings smells.function_complexity.threshold is 25, above qlty's 18: parsers are one big match" ]
}

@test "malformed findings settings exit 2" {
  local_repo
  check a "touch $T/ran"
  good=$(jq -c '.findings = {radarlint: ["python"], rules: {"python:S3776": false},
    smells: {function_complexity: {enable: true, threshold: 18}}, duplication: {nodes_threshold: 64}}' "$ASSAY_CONFIG")
  printf '%s' "$good" >"$ASSAY_CONFIG"
  run "$assay" check
  [ "$status" -eq 0 ]
  rm "$T/ran"
  bad() {
    printf '%s' "$2" >"$ASSAY_CONFIG"
    fails_closed "$1"
  }
  bad "findings not an object" "$(jq -c '.findings = []' <<<"$good")"
  bad "radarlint for another language" "$(jq -c '.findings.radarlint = ["java"]' <<<"$good")"
  bad "a rule not on or off" "$(jq -c '.findings.rules["python:S1"] = "off"' <<<"$good")"
  bad "a rule key that is not a Sonar key" "$(jq -c '.findings.rules["python:S1\nx=1"] = false' <<<"$good")"
  bad "an unknown smell" "$(jq -c '.findings.smells.long_lines = {enable: true, threshold: 1}' <<<"$good")"
  bad "a threshold of zero" "$(jq -c '.findings.smells.function_complexity.threshold = 0' <<<"$good")"
  bad "a fractional threshold" "$(jq -c '.findings.smells.function_complexity.threshold = 1.5' <<<"$good")"
  bad "enable not a boolean" "$(jq -c '.findings.smells.function_complexity.enable = 1' <<<"$good")"
  bad "nodes_threshold not a number" "$(jq -c '.findings.duplication.nodes_threshold = "64"' <<<"$good")"
  bad "a setting's loosening that says nothing" \
    "$(jq -c '.loosenings = [{check: "findings", kind: "setting", reason: "r"}]' <<<"$good")"
}
