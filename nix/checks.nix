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

  # The module with one default check, `demo`, and a repo's own definitions.
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

  expectations = {
    "turning a default off without a reason fails evaluation" = !evaluates {
      assay.checks.demo.enable = false;
    };
    "redefining a default's exec without a reason fails evaluation" = !evaluates {
      assay.checks.demo.exec = "echo mine";
    };
    "a loosening without a reason fails an assertion" = builtins.any (a: !a.assertion)
      (evalWith { assay.checks.demo.enable = false; }).assertions;
    "a loosening with a reason evaluates" = evaluates {
      assay.checks.demo = {
        enable = false;
        reason = "why";
      };
    };
    "the repo's own check is no loosening" = evaluates { assay.checks.own.exec = "true"; };
    "a check name that cannot be a file name fails evaluation" = !evaluates {
      assay.checks."a/b".exec = "true";
    };
    "ASSAY_SEED has a fixed default" = plain.env.ASSAY_SEED == "42";
    "assay.seed sets ASSAY_SEED" = own.env.ASSAY_SEED == "7";
    "the hook runs the fast checks through devenv shell" = plain.git-hooks.hooks.assay == {
      enable = true;
      name = "assay check --fast";
      entry = "devenv shell -- assay check --fast";
      pass_filenames = false;
      always_run = true;
    };
    "a plain definition changes a hook field" = own.git-hooks.hooks.assay.entry == "other";
    "enterTest runs assay check" = lib.hasInfix "assay check\n" plain.enterTest;
    "packages has the CLI" = map (p: p.name) plain.packages == [ "assay" ];
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
        patchShebangs assay.sh
        shellcheck assay.sh test/helpers.bash test/devenv/helpers.bash
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
        jq -e '. == {version: 1, checks: {demo: {exec: "true", fast: true, enable: true, requires: null}}, loosenings: []}' \
          ${plain.env.ASSAY_CONFIG}
        jq -e '.checks.demo.enable == false and .loosenings == [{check: "demo", kind: "off", reason: "off for the test"}]' \
          ${off.env.ASSAY_CONFIG}
        jq -e '.checks.demo.exec == "echo mine" and .loosenings == [{check: "demo", kind: "exec", reason: "mine for the test"}]' \
          ${exec.env.ASSAY_CONFIG}
        jq -e '.checks.own == {exec: "make lint", fast: false, enable: true, requires: "Makefile"} and .loosenings == []' \
          ${own.env.ASSAY_CONFIG}
        touch $out
      '';
}
