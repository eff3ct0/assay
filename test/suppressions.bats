bats_require_minimum_version 1.5.0
load helpers

# suppressions: a new suppression on new code names the rule it silences and gives a reason. A marker with a reason
# field gives it there; one without takes a comment on the same line or the line above.

# This file is a shell file, which the check reads for shellcheck's directives: shell fixtures spell the tool's name
# through this variable, so that this file holds none.
sc=shellcheck

# sup: assay builtin suppressions against $base, the commit the test's change starts from.
sup() {
  run --separate-stderr "$assay" builtin suppressions --base "$base"
  echo "$output"
  echo "$stderr"
}

# start: a repo whose base is its first commit.
start() {
  local_repo
  base=$(sha HEAD)
}

# problems: the problem lines of the last run, without the source lines under them and the closing line.
problems() { grep -E '^[^ ].*:[0-9]+: ' <<<"$output" || true; }

@test "a blanket noqa, an eslint-disable-next-line without a reason and a @ts-ignore fail" {
  start
  printf '%s\n' 'import os' 'x = 1  # noqa' >app.py
  printf '%s\n' '// eslint-disable-next-line no-console' 'console.log(1);' '// @ts-ignore' 'f(x);' >web.ts
  sup
  [ "$status" -eq 1 ]
  expected="app.py:2: noqa names no rule and gives no reason; write it like: # noqa: E501  # <why> (or with the reason in a comment on the line above)
    x = 1  # noqa
web.ts:1: eslint-disable-next-line gives no reason; give one, like: // eslint-disable-next-line no-console -- <why>
    // eslint-disable-next-line no-console
web.ts:3: @ts-ignore is not allowed; use @ts-expect-error, which fails once the error is gone, like: // @ts-expect-error TS2345: <why>
    // @ts-ignore
3 new suppressions fall short: each one names the rule it silences and gives a reason."
  diff <(echo "$expected") <(echo "$output")
}

@test "suppressions that name their rule and give a reason pass, in every language" {
  start
  cat >app.py <<'EOF'
import os  # noqa: F401  # re-exported for the plugin API
x = "a" * 200  # noqa: E501, W505 # a URL that cannot be split
# The stub is untyped.
y = untyped()  # type: ignore[no-untyped-call]
z = w.attr  # pyright: ignore[reportAttributeAccessIssue]  # set by the decorator
if TYPE_CHECKING:  # pragma: no cover  # only for the type checker
    pass
# ruff: noqa: E402  # the path setup must come first
# qlty-ignore(radarlint-python:python:S1192): the literals are the protocol
EOF
  cat >web.ts <<'EOF'
// eslint-disable-next-line no-console -- the CLI prints to the console
console.log(x);
/* eslint-disable no-restricted-syntax, max-lines -- generated code */
// oxlint-disable-next-line no-unused-vars -- kept for the API
// @ts-expect-error TS2345: the fixture is partial on purpose
f(partial);
/* @ts-expect-error TS2322 -- the test passes a wrong type */
// Stryker disable next-line EqualityOperator: both boundaries are equivalent here
// qlty-ignore(eslint:camelcase): public API cannot be renamed
const a = 1; // eslint-disable-line no-magic-numbers -- the protocol's version
/* eslint-disable-next-line
   no-console
   -- the CLI prints */
EOF
  cat >lib.rs <<'EOF'
#![allow(unused, reason = "scaffolding until the API lands")]
#[allow(clippy::too_many_lines, reason = "one match over every opcode")]
fn f() {}
#[expect(
    dead_code,
    reason = "used by the next migration"
)]
fn g() {}
// The mutant is equivalent: both branches return the same value.
#[mutants::skip]
fn h() {}
#[mutants::skip] // equivalent mutant
fn i() {}
EOF
  cat >Main.scala <<'EOF'
@nowarn("cat=deprecation") // the old API until 2.0
def f = ???
// WartRemover cannot see the guard.
@SuppressWarnings(Array("org.wartremover.warts.Var"))
var x = 0 // scalafix:ok DisableSyntax.var; mutable by design
// scalafix:off DisableSyntax.null; the Java API returns null
EOF
  printf '%s\n' "# $sc disable=SC2086 # word splitting is wanted" 'echo $flags' \
    "# The caller sources it." "# $sc source=lib.sh disable=SC1091" '. lib.sh' >run.sh
  sup
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "each marker that names no rule or gives no reason fails, and nothing else does" {
  start
  cat >app.py <<'EOF'
a = 1  # noqa
b = 1  # noqa: E501
c = f()  # type: ignore
d = f()  # type: ignore[call-arg]
# ruff: noqa
if x:  # pragma: no cover
    pass
e = 1  # pyright: ignore
# qlty-ignore: radarlint-python:python:S1192
EOF
  cat >web.ts <<'EOF'
// eslint-disable-next-line
/* eslint-disable */
// eslint-disable-next-line -- the CLI prints
// @ts-nocheck
// @ts-expect-error
// @ts-expect-error: the fixture is partial
// @ts-expect-error TS2345
// Stryker disable next-line all: noisy
// Stryker disable next-line EqualityOperator
// qlty-ignore(eslint): public API
// oxlint-disable no-console
EOF
  cat >lib.rs <<'EOF'
#[allow(dead_code)]
fn f() {}
#[expect(reason = "nothing named")]
fn g() {}
#[expect(
    dead_code,
)]
fn h() {}
#[mutants::skip]
fn i() {}
EOF
  cat >Main.scala <<'EOF'
@nowarn
def f = ???
@nowarn("cat=deprecation")
def g = ???
var x = 0 // scalafix:off
var y = 0 // scalafix:ok DisableSyntax.var
@SuppressWarnings(Array("org.wartremover.warts.Var"))
var z = 0
EOF
  printf '%s\n' "# $sc disable=SC2086" 'echo $flags' "# $sc disable=all # anything goes" >run.sh
  sup
  [ "$status" -eq 1 ]
  expected="Main.scala:1: @nowarn names no rule and gives no reason
Main.scala:3: @nowarn gives no reason
Main.scala:5: scalafix:off names no rule and gives no reason
Main.scala:6: scalafix:ok gives no reason
Main.scala:7: @SuppressWarnings gives no reason
app.py:1: noqa names no rule and gives no reason
app.py:2: noqa gives no reason
app.py:3: type: ignore names no rule and gives no reason
app.py:4: type: ignore gives no reason
app.py:5: ruff: noqa names no rule and gives no reason
app.py:6: pragma: no cover gives no reason
app.py:8: pyright: ignore names no rule and gives no reason
app.py:9: qlty-ignore gives no reason
lib.rs:1: #[allow] gives no reason
lib.rs:3: #[expect] names no rule
lib.rs:5: #[expect] gives no reason
lib.rs:9: #[mutants::skip] gives no reason
run.sh:1: $sc disable gives no reason
run.sh:3: $sc disable names no rule
web.ts:1: eslint-disable-next-line names no rule and gives no reason
web.ts:2: eslint-disable names no rule and gives no reason
web.ts:3: eslint-disable-next-line names no rule
web.ts:4: @ts-nocheck silences the whole file
web.ts:5: @ts-expect-error names no rule and gives no reason
web.ts:6: @ts-expect-error names no rule
web.ts:7: @ts-expect-error gives no reason
web.ts:8: Stryker disable names no rule
web.ts:9: Stryker disable gives no reason
web.ts:10: qlty-ignore names no rule
web.ts:11: oxlint-disable gives no reason"
  diff <(echo "$expected") <(problems | sed -E 's/[;,] (write|name|give|fix|use) .*//; s/ is not allowed.*/ is not allowed/')
}

@test "a suppression already present at the base never fails, even on a line the change modifies" {
  local_repo
  printf '%s\n' 'a = 1  # noqa' 'b = 2' 'c = f()  # type: ignore' >app.py
  git add app.py
  git commit --quiet -m old
  base=$(sha HEAD)
  printf '%s\n' 'a = 10  # noqa' 'b = 20' 'c = g()  # type: ignore' 'd = 4' >app.py
  sup
  [ "$status" -eq 0 ]
  # A changed rule list is a new suppression.
  printf '%s\n' 'a = 10  # noqa' 'b = 20' 'c = g()  # type: ignore[call-arg]' >app.py
  sup
  [ "$status" -eq 1 ]
  [ "$(problems)" = "app.py:3: type: ignore gives no reason; give one, like: # type: ignore[attr-defined]  # <why> (or in a comment on the line above)" ]
  # One old blanket noqa does not let a second one in.
  printf '%s\n' 'a = 10  # noqa' 'b = 20  # noqa' 'c = g()  # type: ignore' >app.py
  sup
  [ "$status" -eq 1 ]
  [[ $(problems) == "app.py:"[12]": noqa names no rule and gives no reason"* ]]
}

@test "a reason on the line above counts only for markers without a reason field" {
  start
  printf '%s\n' '# A URL that cannot be split.' 'x = "a" * 200  # noqa: E501' >app.py
  printf '%s\n' '// The CLI prints to the console.' '// eslint-disable-next-line no-console' 'console.log(1);' >web.ts
  printf '%s\n' '// The lines are counted by the parser.' '#[allow(clippy::too_many_lines)]' 'fn f() {}' >lib.rs
  sup
  [ "$status" -eq 1 ]
  [ "$(problems | cut -d' ' -f1-2)" = "$(printf '%s\n' 'lib.rs:2: #[allow]' 'web.ts:2: eslint-disable-next-line')" ]
}

@test "a comment above that is itself a suppression is no reason" {
  start
  printf '%s\n' '# noqa: F401' 'y = 2  # noqa: E501' >app.py
  sup
  [ "$status" -eq 1 ]
  [ "$(problems | wc -l)" -eq 2 ]
}

@test "markers count only in their language: by extension, and by shebang for a shell script without one" {
  start
  printf '%s\n' '# A note' 'Write `x = 1  # noqa` nowhere.' '// @ts-ignore' >README.md
  printf '%s\n' 'x = 1  # @ts-ignore' '# eslint-disable-next-line' >app.py
  printf '%s\n' '#!/usr/bin/env bash' "# $sc disable=SC2086" 'echo $x' >tool
  printf '%s\n' '#!/usr/bin/env python3' "# $sc disable=SC2086" >tool.py-script
  sup
  [ "$status" -eq 1 ]
  [ "$(problems)" = "tool:2: $sc disable gives no reason; give one, like: # $sc disable=SC2086 # <why> (or in a comment on the line above)" ]
}

@test "only new code is read: a suppression on an unchanged line of a changed file passes" {
  local_repo
  printf '%s\n' '// @ts-ignore' 'f(x);' >web.ts
  git add web.ts
  git commit --quiet -m old
  base=$(sha HEAD)
  echo 'g(y);' >>web.ts
  sup
  [ "$status" -eq 0 ]
  echo '// @ts-ignore' >>web.ts
  sup
  [ "$status" -eq 1 ]
  [[ $(problems) == "web.ts:4: @ts-ignore is not allowed"* ]]
}

@test "a multi-line attribute is new when any of its lines is" {
  local_repo
  printf '%s\n' '#[expect(' '    dead_code,' '    reason = "used later"' ')]' 'fn f() {}' >lib.rs
  git add lib.rs
  git commit --quiet -m old
  base=$(sha HEAD)
  printf '%s\n' '#[expect(' '    dead_code,' '    unused_variables,' ')]' 'fn f() {}' >lib.rs
  sup
  [ "$status" -eq 1 ]
  [[ $(problems) == "lib.rs:1: #[expect] gives no reason"* ]]
}

@test "the base comes from ASSAY_BASE, as assay check exports it" {
  upstream
  printf '%s\n' 'x = 1  # noqa' >app.py
  git add app.py
  git commit --quiet -m noqa
  check suppressions "\"$assay\" builtin suppressions"
  run "$assay" check
  [ "$status" -eq 1 ]
  [[ $output == *"app.py:1: noqa names no rule"* ]]
  run "$assay" check --base HEAD
  [ "$status" -eq 0 ]
}
