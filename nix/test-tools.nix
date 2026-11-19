# What `bats test` needs on the PATH, in the flake's devShell and in `nix flake check`'s sandbox: the CLI's own tools,
# ast-grep among them (the guard's command rules run through it; the package brings it on its own), diff-cover for
# coverage of new code, what the default checks' helpers (devenv/bin) run, and the built-in checks' tools: radarlint
# too, which the module brings only to repos with Python or Scala. kcov and qlty only where they run (kcov where
# nixpkgs has it, Linux; qlty on x86_64-linux): elsewhere test/defaults.bats skips assay-bats' tests, and the findings
# tests fail on the missing tool.
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
  # The built-in checks' tools, which assay's devenv module adds to every repo's devenv.
  actionlint
  gitleaks
  oxfmt
  (callPackage ./radarlint.nix { })
]
