# What `bats test` needs on the PATH, in the flake's devShell and in `nix flake check`'s sandbox: the CLI's own tools,
# ast-grep and yq among them (the guard's command rules and the ast-grep check run through ast-grep, and the ast-grep
# check and `assay rule new` read sgconfig.yml with yq, and the Python preset uses it for TOML), diff-cover for
# coverage of new code, what the default checks' helpers (devenv/bin) run, and the built-in checks' tools.
# radarlint is normally only in repos with Python or Scala, and TLC only where the tla check is enabled.
# Elsewhere than Linux, test/defaults.bats skips assay-bats' tests (kcov); the findings tests require qlty.
{ pkgs }:
with pkgs;
let
  qlty = callPackage ./qlty.nix { };
in
lib.optional (lib.meta.availableOn stdenv.hostPlatform kcov) (callPackage ./kcov.nix { })
++ lib.optional (lib.meta.availableOn stdenv.hostPlatform qlty) qlty
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
  uv
  (callPackage ./python-test-env.nix { })
  # The built-in checks' tools, which assay's devenv module adds to every repo's devenv.
  actionlint
  gitleaks
  oxfmt
  (callPackage ./radarlint.nix { })
  # The tla check's tool, which the module brings only to repos that turn the check on.
  tlaplus18
]
