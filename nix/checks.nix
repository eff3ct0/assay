{
  pkgs,
  src,
  home-manager,
  module,
  rulesCheck,
}:
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

  # The home-manager module, in a home with git on and the example rule list, one rule or more of each `on`.
  homeWith =
    config:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        {
          home = {
            username = "alice";
            homeDirectory = "/home/alice";
            stateVersion = "26.05";
          };
          programs.git.enable = true;
        }
        config
      ];
    };
  exampleRules = import ../test/rules/example.nix;
  home = homeWith {
    programs.assay = {
      enable = true;
      rules = exampleRules;
    };
  };
  homeConfig = home.config;
  inherit (homeConfig.programs.assay) rulesFile;
  assayExe = lib.getExe homeConfig.programs.assay.package;

  # Whether a home with these rules evaluates: home-manager throws on an option's type, an option used but not
  # defined, and a failed assertion.
  rulesEvaluate =
    rules:
    (builtins.tryEval
      (homeWith {
        programs.assay = {
          enable = true;
          inherit rules;
        };
      }).activationPackage.drvPath
    ).success;
  rule = {
    name = "r";
    on = "command";
    match.kind = "command";
    message = "m";
    deny = [ "git clone x" ];
    allow = [ "ls" ];
  };
  merged = homeWith {
    imports = [ { programs.assay.rules = [ rule ]; } ];
    programs.assay = {
      enable = true;
      rules = [ (rule // { name = "s"; }) ];
    };
  };
  withoutGit = homeWith {
    programs.git.enable = lib.mkForce false;
    programs.assay.enable = true;
  };
  disabled = homeWith { programs.assay.rules = [ rule ]; };

  homeExpectations = {
    "a home with one rule of each on evaluates" = rulesEvaluate exampleRules;
    "a rule lacking a deny example fails evaluation" = !rulesEvaluate [ (removeAttrs rule [ "deny" ]) ];
    "an empty allow list fails evaluation" = !rulesEvaluate [ (rule // { allow = [ ]; }) ];
    "a rule lacking a message fails evaluation" = !rulesEvaluate [ (removeAttrs rule [ "message" ]) ];
    "a message of two lines fails evaluation" = !rulesEvaluate [ (rule // { message = "a\nb"; }) ];
    "a name that cannot be an id fails evaluation" = !rulesEvaluate [ (rule // { name = "a rule"; }) ];
    "two rules with one name fail evaluation" =
      !rulesEvaluate [
        rule
        rule
      ];
    "a command rule whose match is a string fails evaluation" =
      !rulesEvaluate [ (rule // { match = "git clone"; }) ];
    "a pre-push rule whose match is no check of assay's fails evaluation" =
      !rulesEvaluate [
        (
          rule
          // {
            on = "pre-push";
            match = "main";
          }
        )
      ];
    "a stop example written as a string fails evaluation" =
      !rulesEvaluate [
        (
          rule
          // {
            on = "stop";
            match = "unsaved-work";
            deny = [ "dirty" ];
            allow = [ { } ];
          }
        )
      ];
    "an example with a field its kind lacks fails evaluation" =
      !rulesEvaluate [ (rule // { deny = [ { path = "x"; } ]; }) ];
    "a cwd on a path rule fails evaluation" =
      !rulesEvaluate [
        (
          rule
          // {
            on = "path";
            match = "*";
            cwd = "main-checkout";
            deny = [ "a" ];
            allow = [ "b" ];
          }
        )
      ];
    "several definitions of the rule list merge" =
      lib.sort lib.lessThan (map (r: r.name) merged.config.programs.assay.rules) == [
        "r"
        "s"
      ];
    "the git config registers both hooks, with the rendered rules" =
      homeConfig.programs.git.settings.hook == {
        assay-commit-msg = {
          event = "commit-msg";
          command = "${assayExe} git-hook --rules ${rulesFile} commit-msg";
        };
        assay-pre-push = {
          event = "pre-push";
          command = "${assayExe} git-hook --rules ${rulesFile} pre-push";
        };
      };
    "ASSAY_HITS_LOG is in the user's state directory" =
      homeConfig.home.sessionVariables.ASSAY_HITS_LOG == "/home/alice/.local/state/assay/hits.jsonl";
    "without programs.git, a warning says no commit or push runs the rules" = lib.any (
      w: lib.hasInfix "no commit or push runs assay's rules" w
    ) withoutGit.config.warnings;
    "disabled, the module registers no hook" = !(disabled.config.programs.git.settings ? hook);
  };
  homeFailed = lib.attrNames (lib.filterAttrs (_: ok: !ok) homeExpectations);

  # The example list with an allow example its rule denies.
  badRules = map (
    r: if r.name == "no-clone" then r // { allow = r.allow ++ [ "git clone z" ]; } else r
  ) exampleRules;
  badRulesCheck = rulesCheck {
    inherit pkgs;
    rules =
      (homeWith {
        programs.assay = {
          enable = true;
          rules = badRules;
        };
      }).config.programs.assay.rulesFile;
  };
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
          ast-grep
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
        shellcheck assay.sh nix/rules-check.sh test/helpers.bash test/devenv/helpers.bash test/stub/devenv
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

  home-manager =
    pkgs.runCommand "assay-home-manager"
      {
        nativeBuildInputs = with pkgs; [
          git
          jq
        ];
      }
      ''
        ${lib.concatMapStrings (f: "echo ${lib.escapeShellArg "FAIL: ${f}"} >&2\n") homeFailed}
        ${lib.optionalString (homeFailed != [ ]) "exit 1"}
        # The rendered list is the one the bats suite reads.
        jq -S . ${rulesFile} >rendered.json
        jq -S . ${../test/rules/example.json} >example.json
        diff rendered.json example.json || { echo "FAIL: the rendered rules differ from test/rules/example.json" >&2; exit 1; }
        # assay is on the user's PATH.
        test -x ${home.activationPackage}/home-path/bin/assay
        # The generated git config holds both hooks.
        gitconfig=${home.activationPackage}/home-files/.config/git/config
        [ "$(git config -f "$gitconfig" hook.assay-commit-msg.event)" = commit-msg ]
        [ "$(git config -f "$gitconfig" hook.assay-commit-msg.command)" = "${assayExe} git-hook --rules ${rulesFile} commit-msg" ]
        [ "$(git config -f "$gitconfig" hook.assay-pre-push.event)" = pre-push ]
        [ "$(git config -f "$gitconfig" hook.assay-pre-push.command)" = "${assayExe} git-hook --rules ${rulesFile} pre-push" ]
        # With it as the global git config, in a throwaway repo: a commit whose message matches a commit-msg rule is
        # rejected with the rule's message, and the repo's own commit-msg hook still runs.
        export HOME=$PWD/home GIT_CONFIG_GLOBAL=$gitconfig GIT_CONFIG_NOSYSTEM=1
        export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
        mkdir "$HOME"
        git init --quiet repo
        printf '#!/bin/sh\necho ran >>"%s"\n' "$PWD/own-hook.log" >repo/.git/hooks/commit-msg
        chmod +x repo/.git/hooks/commit-msg
        if git -C repo commit --allow-empty -m "$(printf 'Fix\n\nCo-Authored-By: A <a@example.com>')" 2>err; then
          echo "FAIL: the commit with a Co-Authored-By trailer was accepted" >&2
          exit 1
        fi
        cat err
        grep -qF 'assay: no-coauthor: A commit names no co-author: remove the Co-Authored-By trailer.' err
        [ "$(wc -l <own-hook.log)" -eq 1 ]
        git -C repo commit --quiet --allow-empty -m Fix
        [ "$(wc -l <own-hook.log)" -eq 2 ]
        touch $out
      '';

  # The check builder over the example list passes; over one where an allow example is denied it fails.
  rules-check = rulesCheck {
    inherit pkgs;
    rules = rulesFile;
  };
  rules-check-fails =
    pkgs.runCommand "assay-rules-check-fails"
      {
        failure = pkgs.testers.testBuildFailure badRulesCheck;
      }
      ''
        grep -qF 'FAIL no-clone allow 3: git clone z: denied:' $failure/testBuildFailure.log
        [ "$(cat $failure/testBuildFailure.exit)" -ne 0 ]
        touch $out
      '';
}
