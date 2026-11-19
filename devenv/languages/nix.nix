# Nix's default checks, on with languages.nix.enable (see ../defaults.nix for the shape). Every tool runs over the
# .nix files git sees: never `.`, which would reach `.devenv/` and ignored files. Nix has no coverage tool.
{
  config,
  lib,
  pkgs,
}:
let
  helpers = pkgs.callPackage ../../nix/check-helpers.nix { };
  nixFiles = "assay-files '**/*.nix' | xargs -0 -r";
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
