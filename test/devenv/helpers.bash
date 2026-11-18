# Shared setup for the devenv tests: throwaway repos whose devenv.yaml imports assay/devenv from a git+file: copy of
# this working tree (standing in for github:eff3ct0/assay), run with the devenv on the PATH. They need the network
# the first time (nixpkgs, git-hooks.nix) and take a few minutes.

# git-hooks.nix at a fixed revision, so that a run does not depend on upstream's latest.
git_hooks_rev=204b6977e00caac19e2313015a598543ca7be150

# copy_assay <dir>: this working tree, uncommitted changes included, as a git repo with one commit: the files git
# sees, not ignored ones such as .devenv/.
copy_assay() {
  local src f
  src=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  mkdir -p "$1"
  while IFS= read -r -d '' f; do
    if [ -e "$src/$f" ]; then (cd "$src" && cp -P --parents "$f" "$1/"); fi
  done < <(git -C "$src" ls-files -z --cached --others --exclude-standard)
  git -C "$1" init --quiet
  git -C "$1" add -A
  git -C "$1" commit --quiet -m copy
}

setup_file() {
  command -v devenv >/dev/null || {
    echo "devenv is not on the PATH" >&2
    return 1
  }
  export GIT_CONFIG_GLOBAL=$BATS_FILE_TMPDIR/gitconfig GIT_CONFIG_NOSYSTEM=1
  git config --global user.name Test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  git config --global gc.auto 0
  git config --global maintenance.auto false
  unset ASSAY_CONFIG ASSAY_BASE ASSAY_SEED GITHUB_EVENT_PATH ASSAY_HITS_LOG ASSAY_AGENT
  export NIXPKGS_REV
  NIXPKGS_REV=$(jq -r .nodes.nixpkgs.locked.rev "$BATS_TEST_DIRNAME/../../flake.lock")
  export ASSAY=$BATS_FILE_TMPDIR/assay
  copy_assay "$ASSAY"
  # The same module with one default check, `demo`.
  export ASSAY_WITH_DEFAULT=$BATS_FILE_TMPDIR/assay-with-default
  copy_assay "$ASSAY_WITH_DEFAULT"
  cat >"$ASSAY_WITH_DEFAULT/devenv/defaults.nix" <<'EOF'
_: {
  demo = {
    exec = "echo assay's demo";
    fast = true;
  };
}
EOF
  git -C "$ASSAY_WITH_DEFAULT" commit --quiet -am "a default check"
}

setup() {
  T=$BATS_TEST_TMPDIR
}

# consumer [assay source]: a repo whose devenv.yaml imports assay/devenv (plus git-hooks, which devenv 2.4.0
# needs), as the current directory. Its devenv.nix is written with devenv_nix.
consumer() {
  mkdir "$T/repo"
  cd "$T/repo" || return 1
  git init --quiet
  cat >devenv.yaml <<EOF
inputs:
  nixpkgs:
    url: github:NixOS/nixpkgs/$NIXPKGS_REV
  git-hooks:
    url: github:cachix/git-hooks.nix/$git_hooks_rev
    inputs:
      nixpkgs:
        follows: nixpkgs
  assay:
    url: git+file://${1:-$ASSAY}
    flake: false
imports:
  - assay/devenv
EOF
  printf '%s\n' .devenv/ .devenv.flake.nix devenv.lock .pre-commit-config.yaml >.gitignore
  echo '{ }' >devenv.nix
  git add -A
  git commit --quiet -m init
}

# devenv_nix <text>: the repo's devenv.nix.
devenv_nix() {
  echo "$1" >devenv.nix
}

# hook <field>: a field of the assay hook in the generated pre-commit configuration.
hook() {
  grep -v '^#' .pre-commit-config.yaml | jq -c ".repos[].hooks[] | select(.id == \"assay\") | .$1"
}
