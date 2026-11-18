# What `bats test` needs on the PATH, in the flake's devShell and in `nix flake check`'s sandbox: the CLI's own tools,
# diff-cover for coverage of new code, and what the default checks' helpers (devenv/bin) run.
{ pkgs }:
with pkgs;
[
  bats
  shellcheck
  nixfmt
  jq
  git
  python3Packages.diff-cover
  (callPackage ./kcov.nix { })
  shfmt
  nixf
]
