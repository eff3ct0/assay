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

  # The analyzer's policy (`assay findings` and the `findings` check): qlty's own smell thresholds, and Sonar's
  # cognitive complexity off in radarlint, since complexity has one source, qlty's smells.
  smellDefaults = {
    boolean_logic = 4;
    file_complexity = 50;
    function_complexity = 18;
    function_parameters = 6;
    identical_code = 15;
    nested_control_flow = 5;
    return_statements = 6;
    similar_code = 15;
  };
  nodesThresholdDefault = 64;
  ruleDefaults = {
    "python:S3776" = false;
    "scala:S3776" = false;
  };
  # radarlint, a JVM, runs only for the languages the repo enables.
  radarlintLanguages = builtins.filter (l: config.languages.${l}.enable or false) [
    "python"
    "scala"
  ];

  # A loosening of the analyzer's policy: a smell turned off or its threshold raised, a rule turned off. Each is a
  # setting of the findings check.
  findingsLoosenings =
    map
      (
        l:
        l
        // {
          check = "findings";
          kind = "setting";
        }
      )
      (
        lib.concatLists (
          lib.mapAttrsToList (
            kind: default:
            let
              s = cfg.findings.smells.${kind};
            in
            if !s.enable then
              [
                {
                  what = "smells.${kind} is off";
                  where = "assay.findings.smells.${kind}.reason";
                  inherit (s) reason;
                }
              ]
            else if s.threshold > default then
              [
                {
                  what = "smells.${kind}.threshold is ${toString s.threshold}, above qlty's ${toString default}";
                  where = "assay.findings.smells.${kind}.reason";
                  inherit (s) reason;
                }
              ]
            else
              [ ]
          ) smellDefaults
        )
        ++ (
          let
            d = cfg.findings.smells.duplication;
          in
          lib.optional (d.nodes_threshold > nodesThresholdDefault) {
            what = "smells.duplication.nodes_threshold is ${toString d.nodes_threshold}, above qlty's ${toString nodesThresholdDefault}";
            where = "assay.findings.smells.duplication.reason";
            inherit (d) reason;
          }
        )
        ++ lib.concatLists (
          lib.mapAttrsToList (
            key: r:
            if !r.enable && (ruleDefaults.${key} or true) then
              [
                {
                  what = "rule ${key} is off";
                  where = "assay.findings.rules.${builtins.toJSON key}.reason";
                  inherit (r) reason;
                }
              ]
            else
              [ ]
          ) cfg.findings.rules
        )
      );

  # The coverage of new code assay asks for, in percent of the new lines a check's report can cover.
  defaultNewCode = 80;

  # A loosening: the repo turns one of assay's default checks off, redefines its exec, or changes the coverage
  # report it is measured with; or it lowers assay.coverage.newCode; or it loosens the analyzer (findingsLoosenings).
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
    }
    ++ findingsLoosenings;
  unreasoned = builtins.filter (l: l.reason == null) loosenings;
  describe =
    l:
    {
      off = "${l.check} turned off";
      exec = "${l.check}'s exec redefined";
      coverage = "${l.check}'s coverage changed";
      new-code = "assay.coverage.newCode lowered to ${toString l.newCode}, under assay's ${toString l.default}";
      setting = l.what;
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

  # radarlint's rule keys become lines of a properties file.
  badRules = builtins.filter (k: builtins.match "[a-z]+:[A-Za-z0-9_-]+" k == null) (
    lib.attrNames cfg.findings.rules
  );
  badRulesMessage = "assay: assay.findings.rules takes Sonar's rule keys, like python:S3776: ${lib.concatStringsSep ", " badRules}";

  # What `assay check` reads, through ASSAY_CONFIG. It cannot be produced while a check name is bad or a loosening
  # has no reason, whatever path of devenv's evaluation asks for it.
  configFile =
    if badNames != [ ] then
      throw badNamesMessage
    else if badRules != [ ] then
      throw badRulesMessage
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
            else if l.kind == "setting" then
              {
                inherit (l)
                  check
                  kind
                  what
                  reason
                  ;
              }
            else
              { inherit (l) check kind reason; }
          ) loosenings;
          findings = {
            radarlint = radarlintLanguages;
            rules = lib.mapAttrs (_: r: r.enable) cfg.findings.rules;
            smells = lib.mapAttrs (kind: _: {
              inherit (cfg.findings.smells.${kind}) enable threshold;
            }) smellDefaults;
            duplication = { inherit (cfg.findings.smells.duplication) nodes_threshold; };
          };
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

  reasonOption = mkOption {
    type = types.nullOr types.nonEmptyStr;
    default = null;
    description = ''
      Why the repo loosens the analyzer's policy here. A loosening without a reason fails evaluation; with one,
      `assay check` lists it in its header on every run.
    '';
  };
  smellModule = kind: threshold: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether qlty reports the ${kind} smell. Turning it off is a loosening and needs `reason`.";
      };
      threshold = mkOption {
        type = types.ints.positive;
        default = threshold;
        description = "qlty's ${kind} threshold (qlty's default, ${toString threshold}). Raising it is a loosening and needs `reason`.";
      };
      reason = reasonOption;
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
    findings = {
      smells = mkOption {
        type = types.submodule {
          options =
            lib.mapAttrs (
              kind: threshold:
              mkOption {
                type = types.submodule (smellModule kind threshold);
                default = { };
                description = "qlty's `[smells.${kind}]`.";
              }
            ) smellDefaults
            // {
              duplication = mkOption {
                type = types.submodule {
                  options = {
                    nodes_threshold = mkOption {
                      type = types.ints.positive;
                      default = nodesThresholdDefault;
                      description = ''
                        The size, in syntax nodes, from which qlty compares code for clones, in every language
                        (qlty's default, ${toString nodesThresholdDefault}, which also replaces Rust's own, 50). Raising
                        it is a loosening and needs `reason`.
                      '';
                    };
                    reason = reasonOption;
                  };
                };
                default = { };
                description = "qlty's `[smells.duplication]`.";
              };
            };
        };
        default = { };
        description = ''
          qlty's smells, which `assay findings` shows and whose new ones fail the `findings` check: each kind's
          `enable` and `threshold`, with qlty's names and defaults.
        '';
      };
      rules = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Whether radarlint reports the rule. Turning one off is a loosening and needs `reason`.";
              };
              reason = reasonOption;
            };
          }
        );
        default = { };
        example = lib.literalExpression ''{ "python:S1192" = { enable = false; reason = "..."; }; }'';
        description = ''
          radarlint's rules, by Sonar's key (`python:S3776`). A rule nobody wants is turned off, not downgraded:
          every finding on new code fails the `findings` check. Sonar's cognitive complexity (`S3776`) is off by
          default, since qlty's smells measure complexity.
        '';
      };
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
    assay.findings.rules = lib.mapAttrs (_: enable: { enable = mkDefault enable; }) ruleDefaults;

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
        assertion = badRules == [ ];
        message = badRulesMessage;
      }
      {
        assertion = unreasoned == [ ];
        message = unreasonedMessage;
      }
    ];
  };
}
