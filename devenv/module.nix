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
  defaultTools = lib.concatMap (d: d.packages or [ ]) (lib.attrValues defaults');

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

  # A loosening of the analyzer's policy: a smell turned off or its threshold raised, a rule turned off.
  findingsLoosenings =
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
              option = "assay.findings.smells.${kind}.reason";
              inherit (s) reason;
            }
          ]
        else if s.threshold > default then
          [
            {
              what = "smells.${kind}.threshold is ${toString s.threshold}, above qlty's ${toString default}";
              option = "assay.findings.smells.${kind}.reason";
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
        option = "assay.findings.smells.duplication.reason";
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
              option = "assay.findings.rules.${builtins.toJSON key}.reason";
              inherit (r) reason;
            }
          ]
        else
          [ ]
      ) cfg.findings.rules
    );

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
  unreasonedChecks = builtins.filter (l: l.reason == null) loosenings;
  unreasonedFindings = builtins.filter (l: l.reason == null) findingsLoosenings;
  unreasoned = unreasonedChecks ++ unreasonedFindings;
  unreasonedMessage = lib.concatStringsSep "\n" (
    lib.optional (unreasonedChecks != [ ]) ''
      assay: a loosening needs a reason; set assay.checks.<name>.reason for:
      ${lib.concatMapStringsSep "\n" (
        l: "  - ${l.check}: ${if l.kind == "off" then "turned off" else "exec redefined"}"
      ) unreasonedChecks}''
    ++ lib.optional (unreasonedFindings != [ ]) ''
      assay: a loosening of the analyzer needs a reason; set:
      ${lib.concatMapStringsSep "\n" (l: "  - ${l.option}: ${l.what}") unreasonedFindings}''
  );

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
          loosenings =
            map (l: { inherit (l) check kind reason; }) loosenings
            ++ map (l: {
              check = "findings";
              kind = "setting";
              inherit (l) what reason;
            }) findingsLoosenings;
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
                        The size, in syntax nodes, from which qlty compares code for clones (qlty's default,
                        ${toString nodesThresholdDefault}; Rust's own, 50, stays). Raising it is a loosening and needs
                        `reason`.
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

    packages = [ assay ] ++ defaultTools;
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
