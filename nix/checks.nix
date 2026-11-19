{ pkgs, src }:
let
  inherit (pkgs) lib;

  # A stand-in for the devenv options the module sets or reads, so that it evaluates without devenv.
  devenvStub =
    { config, ... }:
    {
      options = {
        devenv.root = lib.mkOption {
          type = lib.types.str;
          default = "/repo";
        };
        languages.javascript = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          directory = lib.mkOption {
            type = lib.types.str;
            default = config.devenv.root;
          };
        };
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

  # The module with the given default checks, and a repo's own definitions.
  evalModule =
    defaults: repo:
    (lib.evalModules {
      modules = [
        devenvStub
        (import ../devenv/module.nix { inherit defaults; })
        { _module.args.pkgs = pkgs; }
        repo
      ];
    }).config;

  # The module with one default check, `demo`.
  evalWith = evalModule (_: {
    demo = {
      exec = "true";
      fast = true;
    };
  });

  # The module with assay's own default checks, the built-in ones.
  evalBuiltin = evalModule (import ../devenv/defaults.nix);
  builtinPlain = evalBuiltin { };
  builtinJavascript = evalBuiltin { languages.javascript.enable = true; };
  javascriptIn =
    directory:
    evalBuiltin {
      languages.javascript = {
        enable = true;
        inherit directory;
      };
    };
  builtinFrontend = javascriptIn "./frontend";
  oxfmtExec = config: config.assay.checks.oxfmt.exec;

  # Whether the configuration file can be produced.
  evaluates = repo: (builtins.tryEval (evalWith repo).env.ASSAY_CONFIG).success;
  evaluatesBuiltin = repo: (builtins.tryEval (evalBuiltin repo).env.ASSAY_CONFIG).success;

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
    "packages has the CLI" = map (p: p.name) plain.packages == [ "assay" ];
    "the built-in checks' tools join every repo's devenv, beside the CLI" =
      map lib.getName builtinPlain.packages == [
        "assay"
        "actionlint"
        "gitleaks"
        "oxfmt"
      ];
    "a JavaScript directory given absolute, relative or with a trailing slash is the same pattern" =
      lib.all (d: oxfmtExec (javascriptIn d) == oxfmtExec builtinFrontend)
        [
          "/repo/frontend"
          "frontend"
          "frontend/"
        ];
    "a JavaScript directory that is the root adds no prefix" =
      lib.all (d: oxfmtExec (javascriptIn d) == oxfmtExec builtinJavascript)
        [
          "/repo"
          "."
          "./"
        ];
    "redefining a built-in check's exec is a loosening" =
      !evaluatesBuiltin { assay.checks.oxfmt.exec = "oxfmt --check ."; };
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
          gawk
          actionlint
          gitleaks
          oxfmt
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
        jq -e '. == {version: 1, checks: {demo: {exec: "true", fast: true, enable: true, requires: null}}, loosenings: []}' \
          ${plain.env.ASSAY_CONFIG}
        jq -e '.checks.demo.enable == false and .loosenings == [{check: "demo", kind: "off", reason: "off for the test"}]' \
          ${off.env.ASSAY_CONFIG}
        jq -e '.checks.demo.exec == "echo mine" and .loosenings == [{check: "demo", kind: "exec", reason: "mine for the test"}]' \
          ${exec.env.ASSAY_CONFIG}
        jq -e '.checks.own == {exec: "make lint", fast: false, enable: true, requires: "Makefile"} and .loosenings == []' \
          ${own.env.ASSAY_CONFIG}
        # The built-in checks give the configurations the bats suite runs.
        same() {
          jq -S . "$1" >a.json
          jq -S . "$2" >b.json
          diff a.json b.json || { echo "FAIL: $1 differs from $2" >&2; exit 1; }
        }
        same ${builtinPlain.env.ASSAY_CONFIG} ${../test/defaults/plain.json}
        same ${builtinJavascript.env.ASSAY_CONFIG} ${../test/defaults/javascript.json}
        same ${builtinFrontend.env.ASSAY_CONFIG} ${../test/defaults/javascript-frontend.json}
        touch $out
      '';
}
