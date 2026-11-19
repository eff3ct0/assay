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

  defaults' = defaults { inherit config lib pkgs; };
  # The checks, without the tools each one lists.
  defaultChecks = lib.mapAttrs (_: d: removeAttrs d [ "packages" ]) defaults';
  defaultTools = lib.unique (lib.concatMap (d: d.packages or [ ]) (lib.attrValues defaults'));

  # The coverage of new code assay asks for, in percent of the new lines a check's report can cover.
  defaultNewCode = 80;

  # A loosening: the repo turns one of assay's default checks off, redefines its exec, or changes the coverage
  # report it is measured with; or it lowers assay.coverage.newCode.
  loosenings =
    lib.concatLists (
      lib.mapAttrsToList (
        name: d:
        let
          c = cfg.checks.${name};
          loosening = kind: {
            check = name;
            inherit kind;
            inherit (c) reason;
            where = "assay.checks.${name}.reason";
          };
        in
        if (d.enable or true) && !c.enable then
          [ (loosening "off") ]
        else
          lib.optional (c.enable && c.exec != d.exec) (loosening "exec")
          ++ lib.optional (c.enable && (d.coverage or null) != null && c.coverage != d.coverage) (
            loosening "coverage"
          )
      ) defaultChecks
    )
    ++ lib.optional (cfg.coverage.newCode < defaultNewCode) {
      kind = "new-code";
      inherit (cfg.coverage) newCode reason;
      default = defaultNewCode;
      where = "assay.coverage.reason";
    };
  unreasoned = builtins.filter (l: l.reason == null) loosenings;
  describe =
    l:
    {
      off = "${l.check} turned off";
      exec = "${l.check}'s exec redefined";
      coverage = "${l.check}'s coverage changed";
      new-code = "assay.coverage.newCode lowered to ${toString l.newCode}, under assay's ${toString l.default}";
    }
    .${l.kind};
  unreasonedMessage = ''
    assay: a loosening needs a reason:
    ${lib.concatMapStringsSep "\n" (l: "  - ${describe l}; set ${l.where}") unreasoned}'';

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
              coverage
              ;
          }) cfg.checks;
          coverage = { inherit (cfg.coverage) newCode; };
          loosenings = map (
            l:
            if l.kind == "new-code" then
              {
                inherit (l)
                  kind
                  newCode
                  default
                  reason
                  ;
              }
            else
              { inherit (l) check kind reason; }
          ) loosenings;
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
      coverage = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        example = "$ASSAY_DIR/coverage/lcov.info";
        description = ''
          The coverage report the check writes, LCOV or Cobertura: a path relative to the repo root, in which
          `$ASSAY_DIR` stands for assay's directory in the git directory (`<git-dir>/assay`, exported to every check).
          `assay check` removes it before the check runs; when the check passes, it runs diff-cover on it against the
          base, and the check fails unless `assay.coverage.newCode` percent of the new lines the report can cover are
          covered. Changing a default check's coverage is a loosening and needs `reason`.
        '';
      };
      reason = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = ''
          Why the repo loosens one of assay's default checks: turns it off, redefines its exec or changes its
          coverage. A loosening without a reason fails evaluation; with one, `assay check` lists it in its header on
          every run.
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
    coverage.newCode = mkOption {
      type = types.ints.between 0 100;
      default = defaultNewCode;
      description = ''
        The percentage of the new lines a check's coverage report can cover that must be covered, for every check
        that declares `coverage`. No exemption for small changes. Lowering it is a loosening and needs
        `assay.coverage.reason`.
      '';
    };
    coverage.reason = mkOption {
      type = types.nullOr types.nonEmptyStr;
      default = null;
      description = "Why the repo lowers `assay.coverage.newCode` below assay's default; `assay check` lists it in its header.";
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

    # The CLI, the tools of assay's default checks, and diff-cover when an enabled check declares coverage.
    packages = [
      assay
    ]
    ++ defaultTools
    ++ lib.optional (lib.any (c: c.enable && c.coverage != null) (
      lib.attrValues cfg.checks
    )) pkgs.python3Packages.diff-cover;
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
