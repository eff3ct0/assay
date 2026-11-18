# assay's default checks, as a function of { config, lib, pkgs } returning
# { <name> = { exec; fast; enable ? true; requires ? null; coverage ? null; packages ? [ ]; }; }. The module sets
# each field but packages with lib.mkDefault, so a plain definition in the repo overrides it; turning one off,
# redefining its exec or changing its coverage is a loosening, which needs `assay.checks.<name>.reason`. packages
# are the tools the check needs, which the module adds to the devenv. Each language's checks are on when the repo
# enables the language in devenv, and are named after their tool.
{
  config,
  lib,
  pkgs,
}:
let
  # The helpers the checks run (bin/): assay-files, assay-nixf-tidy, assay-bats.
  helpers = pkgs.runCommandLocal "assay-check-helpers" { } ''
    mkdir -p $out/bin
    cp ${./bin}/* $out/bin/
    patchShebangs $out/bin
  '';
  kcov = pkgs.callPackage ../nix/kcov.nix { };

  # Every tool runs over the .nix files git sees: never `.`, which would reach `.devenv/` and ignored files.
  nixFiles = "assay-files '**/*.nix' | xargs -0 -r";
  # The shell files git sees, as shfmt -f finds them (by extension or shebang, .bats files included).
  shellFiles = ''assay-files | xargs -0 -r shfmt -f | tr '\n' '\0' | xargs -0 -r'';
in
lib.optionalAttrs config.languages.nix.enable {
  nixfmt = {
    exec = "${nixFiles} nixfmt --check";
    fast = true;
    packages = [
      helpers
      pkgs.nixfmt
    ];
  };
  statix = {
    # statix takes one file at a time; errfmt is its one output without colours.
    exec = "${nixFiles} -n 1 statix check -o errfmt";
    fast = true;
    packages = [
      helpers
      pkgs.statix
    ];
  };
  deadnix = {
    exec = "${nixFiles} env NO_COLOR=1 deadnix --fail";
    fast = true;
    packages = [
      helpers
      pkgs.deadnix
    ];
  };
  nixf-tidy = {
    exec = "${nixFiles} assay-nixf-tidy";
    fast = true;
    packages = [
      helpers
      pkgs.nixf
      pkgs.jq
    ];
  };
  nix-flake-check = {
    exec = "nix flake check";
    requires = "flake.nix";
  };
}
// lib.optionalAttrs config.languages.shell.enable {
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
      kcov
      pkgs.shfmt
    ];
  };
}
