# What `bats test` needs on the PATH, in the flake's devShell and in `nix flake check`'s sandbox: the CLI's own tools,
# diff-cover for coverage of new code, and what the default checks' helpers (devenv/bin) run. kcov only where nixpkgs
# has it (Linux): elsewhere test/defaults.bats skips assay-bats' tests.
{ pkgs }:
with pkgs;
lib.optional (lib.meta.availableOn stdenv.hostPlatform kcov) (callPackage ./kcov.nix { })
++ [
  bats
  shellcheck
  nixfmt
  jq
  git
  python3Packages.diff-cover
  shfmt
  nixf
]
