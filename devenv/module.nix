# assay's devenv module, given its default checks (a function like defaults.nix). devenv.nix applies it to
# defaults.nix; nix/checks.nix applies it to a test default.
{ defaults }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkDefault mkOption types;
  cfg = config.assay;

  # Built with the repo's own pkgs, so the input can stay `flake: false`.
  assay = pkgs.callPackage ../nix/package.nix { };

  defaultChecks = defaults { inherit config lib pkgs; };

  # A loosening: the repo turns one of assay's default checks off, or redefines its exec.
  loosenings = lib.concatLists (
    lib.mapAttrsToList (
      name: d:
      let
        c = cfg.checks.${name};
      in
      if (d.enable or true) && !c.enable then
        [
          {
            check = name;
            kind = "off";
            inherit (c) reason;
          }
        ]
      else if c.enable && c.exec != d.exec then
        [
          {
            check = name;
            kind = "exec";
            inherit (c) reason;
          }
        ]
      else
        [ ]
    ) defaultChecks
  );
  unreasoned = builtins.filter (l: l.reason == null) loosenings;
  unreasonedMessage = ''
    assay: a loosening needs a reason; set assay.checks.<name>.reason for:
    ${lib.concatMapStringsSep "\n" (
      l: "  - ${l.check}: ${if l.kind == "off" then "turned off" else "exec redefined"}"
    ) unreasoned}'';

  # Check names become log file names.
  badNames = builtins.filter (n: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" n == null) (
    lib.attrNames cfg.checks
  );
  badNamesMessage = "assay: check names must match [A-Za-z0-9][A-Za-z0-9._-]*: ${lib.concatStringsSep ", " badNames}";

  # What `assay check` reads, through ASSAY_CONFIG. It cannot be produced while a check name is bad or a loosening
  # has no reason, whatever path of devenv's evaluation asks for it.
  configFile =
    if badNames != [ ] then
      throw badNamesMessage
    else if unreasoned != [ ] then
      throw unreasonedMessage
    else
      pkgs.writeText "assay-config.json" (
        builtins.toJSON {
          version = 1;
          checks = lib.mapAttrs (_: c: {
            inherit (c)
              exec
              fast
              enable
              requires
              ;
          }) cfg.checks;
          loosenings = map (l: { inherit (l) check kind reason; }) loosenings;
        }
      );

  checkModule = {
    options = {
      exec = mkOption {
        type = types.nonEmptyStr;
        description = "Shell command (bash) run from the repo root inside the devenv. A non-zero exit fails the check.";
      };
      fast = mkOption {
        type = types.bool;
        default = false;
        description = ''
          The check only reads source files: no type checking, no build, no test run, no network.
          `assay check --fast` (the pre-commit hook) runs the fast checks only; the whole fast set's budget is 5 s
          with a warm cache. `assay check` runs every enabled check, the fast ones included.
        '';
      };
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether `assay check` runs the check. Turning one of assay's default checks off is a loosening and needs `reason`.";
      };
      requires = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        example = "Cargo.toml";
        description = ''
          A glob relative to the repo root, in git's glob pathspec syntax (`*` stays within a directory, `**/`
          crosses them). When no file git sees in the working tree (tracked or untracked, not ignored) matches it,
          `assay check` prints `skip <name> (no <glob>)` and the check counts as passing.
        '';
      };
      reason = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = ''
          Why the repo loosens one of assay's default checks: turns it off or redefines its exec. A loosening without
          a reason fails evaluation; with one, `assay check` lists it in its header on every run.
        '';
      };
    };
  };
in
{
  options.assay = {
    checks = mkOption {
      type = types.attrsOf (types.submodule checkModule);
      default = { };
      description = "The repo's named checks, run by `assay check`, assay's default checks included.";
    };
    seed = mkOption {
      type = types.ints.between 1 2147483647;
      default = 42;
      description = ''
        The fixed seed of property-based tests, exported as ASSAY_SEED, so that the same tree gives the same result.
        A positive 32-bit integer, which every library's seed accepts. Changing it in a commit is how a repo
        deliberately explores new inputs.
      '';
    };
  };

  config = {
    assay.checks = lib.mapAttrs (_: lib.mapAttrs (_: mkDefault)) defaultChecks;

    packages = [ assay ];
    env.ASSAY_CONFIG = "${configFile}";
    env.ASSAY_SEED = toString cfg.seed;

    # Git runs hooks outside the devenv: the hook enters it. Each field with mkDefault, so a repo changes one with a
    # plain definition.
    git-hooks.hooks.assay = lib.mapAttrs (_: mkDefault) {
      enable = true;
      name = "assay check --fast";
      entry = "devenv shell -- assay check --fast";
      pass_filenames = false;
      always_run = true;
    };

    # `devenv test` runs every pre-commit hook over all files, then this.
    enterTest = ''
      assay check
    '';

    assertions = [
      {
        assertion = badNames == [ ];
        message = badNamesMessage;
      }
      {
        assertion = unreasoned == [ ];
        message = unreasonedMessage;
      }
    ];
  };
}
