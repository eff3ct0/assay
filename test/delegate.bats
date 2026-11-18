bats_require_minimum_version 1.5.0
load helpers

# Outside the repo's devenv (ASSAY_CONFIG unset), assay re-executes itself as `devenv shell -- assay <args>` from the
# repo root. devenv here is test/stub/devenv.

@test "outside the devenv, assay check re-executes itself through devenv shell from the repo root" {
  local_repo
  devenv_files yes
  check zeta true
  check alpha true --fast
  outside_devenv
  mkdir sub
  cd sub
  run --separate-stderr "$assay" check --list
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'alpha (fast)\nzeta')" ]
  [ "$(wc -l <"$T/devenv.calls")" -eq 1 ]
  [[ $(cat "$T/devenv.calls") == "$(printf %q "$T/work") shell -- "* ]]
}

@test "the repo's assay gets the arguments as given, and its output and exit code come back" {
  upstream
  devenv_files yes
  check "fails" "echo failed; exit 3"
  check "passes" "true" --fast
  outside_devenv
  run --separate-stderr "$assay" check --base "HEAD~1" fails passes
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "assay check fails passes · base HEAD~1@$(short HEAD~1) (--base)" ]
  [[ ${lines[-1]} == *"; rerun: assay check --base 'HEAD~1' fails" ]]
  run --separate-stderr "$assay" check --fast
  [ "$status" -eq 0 ]
  run --separate-stderr "$assay" check nope
  [ "$status" -eq 2 ]
  [ "$stderr" = "assay: no check named 'nope' (assay check --list shows them)" ]
}

# not_adopted: the exit-2 message for a repo that has not adopted assay, naming the procedure and saying that the
# adoption is its own change, which the agent tells the user about.
not_adopted() {
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 3 ]
  [ "${stderr_lines[0]}" = "assay: this repo has not adopted assay: $1" ]
  [[ ${stderr_lines[1]} == "assay: adopting it is a change of its own, on its own branch and pull request, made before"*"tell the user"* ]]
  [ "${stderr_lines[2]}" = "assay: the procedure: https://github.com/eff3ct0/assay/blob/main/docs/adoption.md" ]
}

@test "a repo without devenv.nix has not adopted assay: exit 2 naming docs/adoption.md, without calling devenv" {
  local_repo
  check a "touch $T/ran"
  outside_devenv
  run --separate-stderr "$assay" check
  not_adopted "$T/work has no devenv.nix"
  [ ! -e "$T/devenv.calls" ]
  [ ! -e "$T/ran" ]
}

@test "a devenv that does not import assay's module has not adopted assay: exit 2 naming docs/adoption.md" {
  local_repo
  devenv_files no
  check a "touch $T/ran"
  outside_devenv
  run --separate-stderr "$assay" check
  not_adopted "the devenv of $T/work does not import assay's module"
  [ "$(wc -l <"$T/devenv.calls")" -eq 1 ]
  # The same with an assay on the machine's PATH, which the devenv inherits: it never runs.
  run --separate-stderr env PATH="$DEVENV_STUB_PROFILE:$PATH" "$assay" check --list
  not_adopted "the devenv of $T/work does not import assay's module"
  [ "$(wc -l <"$T/devenv.calls")" -eq 2 ]
  [ ! -e "$T/ran" ]
}

@test "an empty ASSAY_CONFIG is outside the devenv too" {
  local_repo
  devenv_files yes
  check a true
  outside_devenv
  run --separate-stderr env ASSAY_CONFIG= "$assay" check --list
  [ "$status" -eq 0 ]
  [ "$output" = a ]
  [ -e "$T/devenv.calls" ]
}

@test "devenv failing before the repo's assay runs exits 2, never 1" {
  local_repo
  devenv_files yes
  check a true
  outside_devenv
  export DEVENV_STUB_FAIL=1
  run --separate-stderr "$assay" check
  [ "$status" -eq 2 ]
  [ "${stderr_lines[0]}" = "error: the stub's evaluation failed" ]
  [ "${stderr_lines[1]}" = "assay: devenv shell failed (exit 1) before assay could run in the repo's devenv" ]
}

@test "outside the devenv, not in a git working tree or without devenv on the PATH, assay exits 2" {
  outside_devenv
  cd "$T"
  run --separate-stderr "$assay" check
  [ "$status" -eq 2 ]
  [ "$stderr" = "assay: not in a git working tree" ]
  local_repo
  devenv_files yes
  mkdir "$T/bin"
  for t in git jq mktemp rm; do ln -s "$(command -v "$t")" "$T/bin/$t"; done
  run --separate-stderr env PATH="$T/bin" "$BASH" "$assay" check
  [ "$status" -eq 2 ]
  [ "$stderr" = "assay: cannot find devenv on the PATH, which assay needs to run inside the repo's devenv" ]
}

@test "guard, git-hook and collect are never delegated" {
  local_repo
  devenv_files yes
  outside_devenv
  for cmd in guard git-hook collect; do
    run --separate-stderr "$assay" "$cmd"
    [ "$status" -eq 2 ]
    [[ ${stderr_lines[0]} == "usage: assay $cmd "* ]]
    [ "${stderr_lines[-1]}" = "assay: $cmd is not implemented yet" ]
  done
  [ ! -e "$T/devenv.calls" ]
}
