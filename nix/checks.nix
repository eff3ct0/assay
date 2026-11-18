{ pkgs, src }:
let
  inherit (pkgs) lib;

  # A stand-in for the devenv options the module sets, so that it evaluates without devenv.
  devenvStub = {
    options = {
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
      git-hooks.hooks = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule { freeformType = lib.types.attrsOf lib.types.anything; }
        );
        default = { };
      };
      enterTest = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
      };
    };
  };

  # The module with two default checks, `demo` and `tested` (which writes a coverage report and needs a tool), and
  # a repo's own definitions.
  evalWith =
    repo:
    (lib.evalModules {
      modules = [
        devenvStub
        (import ../devenv/module.nix {
          defaults = _: {
            demo = {
              exec = "true";
              fast = true;
            };
            tested = {
              exec = "run-tests";
              coverage = "$ASSAY_DIR/t.xml";
              packages = [ pkgs.hello ];
            };
          };
        })
        { _module.args.pkgs = pkgs; }
        repo
      ];
    }).config;

  # Whether the configuration file can be produced.
  evaluates = repo: (builtins.tryEval (evalWith repo).env.ASSAY_CONFIG).success;

  plain = evalWith { };
  off = evalWith {
    assay.checks.demo = {
      enable = false;
      reason = "off for the test";
    };
  };
  exec = evalWith {
    assay.checks.demo = {
      exec = "echo mine";
      reason = "mine for the test";
    };
  };
  own = evalWith {
    assay.checks.own = {
      exec = "make lint";
      requires = "Makefile";
    };
    assay.seed = 7;
    git-hooks.hooks.assay.entry = "other";
  };
  lowered = evalWith {
    assay.coverage = {
      newCode = 50;
      reason = "legacy scripts";
    };
  };
  uncovered = evalWith {
    assay.checks.tested = {
      coverage = null;
      reason = "no report for the test";
    };
  };
  untested = evalWith {
    assay.checks.tested = {
      enable = false;
      reason = "off for the test";
    };
  };
  names = config: map (p: lib.getName p) config.packages;

  expectations = {
    "turning a default off without a reason fails evaluation" =
      !evaluates {
        assay.checks.demo.enable = false;
      };
    "redefining a default's exec without a reason fails evaluation" =
      !evaluates {
        assay.checks.demo.exec = "echo mine";
      };
    "a loosening without a reason fails an assertion" =
      builtins.any (a: !a.assertion)
        (evalWith { assay.checks.demo.enable = false; }).assertions;
    "a loosening with a reason evaluates" = evaluates {
      assay.checks.demo = {
        enable = false;
        reason = "why";
      };
    };
    "the repo's own check is no loosening" = evaluates { assay.checks.own.exec = "true"; };
    "lowering assay.coverage.newCode without a reason fails evaluation" =
      !evaluates {
        assay.coverage.newCode = 79;
      };
    "raising assay.coverage.newCode is no loosening" = evaluates { assay.coverage.newCode = 90; };
    "dropping a default check's coverage without a reason fails evaluation" =
      !evaluates {
        assay.checks.tested.coverage = null;
      };
    "changing a default check's coverage report without a reason fails evaluation" =
      !evaluates {
        assay.checks.tested.coverage = "other.xml";
      };
    "adding coverage to a check is no loosening" = evaluates {
      assay.checks.demo.coverage = "lcov.info";
    };
    "a check name that cannot be a file name fails evaluation" =
      !evaluates {
        assay.checks."a/b".exec = "true";
      };
    "ASSAY_SEED has a fixed default" = plain.env.ASSAY_SEED == "42";
    "assay.seed sets ASSAY_SEED" = own.env.ASSAY_SEED == "7";
    "the hook runs the fast checks through devenv shell" =
      plain.git-hooks.hooks.assay == {
        enable = true;
        name = "assay check --fast";
        entry = "devenv shell -- assay check --fast";
        pass_filenames = false;
        always_run = true;
      };
    "a plain definition changes a hook field" = own.git-hooks.hooks.assay.entry == "other";
    "enterTest runs assay check" = lib.hasInfix "assay check\n" plain.enterTest;
    "packages has the CLI, the default checks' tools and diff-cover" =
      names plain == [
        "assay"
        "hello"
        "diff-cover"
      ];
    "without an enabled check that declares coverage, no diff-cover" =
      names untested == [
        "assay"
        "hello"
      ];
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) expectations);
in
{
  tests =
    pkgs.runCommand "assay-tests"
      {
        nativeBuildInputs = with pkgs; [
          bats
          shellcheck
          git
          jq
          coreutils
        ];
      }
      ''
        cp -r ${src} src
        chmod -R u+w src
        cd src
        patchShebangs assay.sh test/stub
        shellcheck assay.sh test/helpers.bash test/devenv/helpers.bash test/stub/devenv
        bats test
        touch $out
      '';

  module =
    pkgs.runCommand "assay-module"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        ${lib.concatMapStrings (f: "echo ${lib.escapeShellArg "FAIL: ${f}"} >&2\n") failed}
        ${lib.optionalString (failed != [ ]) "exit 1"}
        jq -e '. == {version: 1,
          checks: {
            demo: {exec: "true", fast: true, enable: true, requires: null, coverage: null},
            tested: {exec: "run-tests", fast: false, enable: true, requires: null, coverage: "$ASSAY_DIR/t.xml"}},
          coverage: {newCode: 80}, loosenings: []}' \
          ${plain.env.ASSAY_CONFIG}
        jq -e '.checks.demo.enable == false and .loosenings == [{check: "demo", kind: "off", reason: "off for the test"}]' \
          ${off.env.ASSAY_CONFIG}
        jq -e '.checks.demo.exec == "echo mine" and .loosenings == [{check: "demo", kind: "exec", reason: "mine for the test"}]' \
          ${exec.env.ASSAY_CONFIG}
        jq -e '.checks.own == {exec: "make lint", fast: false, enable: true, requires: "Makefile", coverage: null} and .loosenings == []' \
          ${own.env.ASSAY_CONFIG}
        jq -e '.coverage == {newCode: 50} and .loosenings == [{kind: "new-code", newCode: 50, default: 80, reason: "legacy scripts"}]' \
          ${lowered.env.ASSAY_CONFIG}
        jq -e '.checks.tested.coverage == null and .loosenings == [{check: "tested", kind: "coverage", reason: "no report for the test"}]' \
          ${uncovered.env.ASSAY_CONFIG}
        touch $out
      '';
}
