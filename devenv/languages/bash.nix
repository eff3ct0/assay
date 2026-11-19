# bash's default checks, on with languages.shell.enable (see ../defaults.nix for the shape). The linters run over the
# shell files git sees, as shfmt -f finds them (by extension or shebang, .bats files included); bats runs under kcov,
# whose report is its coverage.
{
  config,
  lib,
  pkgs,
}:
let
  helpers = pkgs.callPackage ../../nix/check-helpers.nix { };
  # nixpkgs has kcov for Linux only: elsewhere bats' check fails on its missing tool (exit 127), until the repo turns
  # it off with a reason.
  kcov = lib.optional (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.kcov) (
    pkgs.callPackage ../../nix/kcov.nix { }
  );
  shellFiles = ''assay-files | xargs -0 -r shfmt -f | tr '\n' '\0' | xargs -0 -r'';
in
lib.optionalAttrs config.languages.shell.enable {
  shellcheck = {
    exec = "${shellFiles} shellcheck";
    fast = true;
    packages = [
      helpers
      pkgs.shfmt
      pkgs.shellcheck
    ];
  };
  shfmt = {
    exec = "${shellFiles} shfmt -d";
    fast = true;
    packages = [
      helpers
      pkgs.shfmt
    ];
  };
  bats = {
    exec = ''assay-bats "$ASSAY_DIR/kcov"'';
    coverage = "$ASSAY_DIR/kcov/bats/cobertura.xml";
    packages = [
      helpers
      pkgs.bats
      pkgs.shfmt
    ]
    ++ kcov;
  };
}
