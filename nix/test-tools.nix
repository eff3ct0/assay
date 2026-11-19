# What `bats test` needs on the PATH, in the flake's devShell and in `nix flake check`'s sandbox: the CLI's own tools,
# ast-grep and yq among them (the guard's command rules and the ast-grep check run through ast-grep, and the ast-grep
# check and `assay rule new` read sgconfig.yml with yq; the package brings both on its own), diff-cover for
# coverage of new code, what the default checks' helpers (devenv/bin) run, and the built-in checks' tools. kcov only
# where nixpkgs has it (Linux): elsewhere test/defaults.bats skips assay-bats' tests.
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
  gawk
  ast-grep
  yq-go
  # The built-in checks' tools, which assay's devenv module adds to every repo's devenv.
  actionlint
  gitleaks
  oxfmt
]
