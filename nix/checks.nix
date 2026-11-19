{
  pkgs,
  src,
  home-manager,
  module,
  rulesCheck,
}:
let
  inherit (pkgs) lib;

  qlty = pkgs.callPackage ./qlty.nix { };

  # A stand-in for the devenv options the module sets or reads, so that it evaluates without devenv.
  devenvStub =
    { config, ... }:
    {
      options = {
        devenv.root = lib.mkOption {
          type = lib.types.str;
          default = "/repo";
        };
        languages = {
          javascript = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            directory = lib.mkOption {
              type = lib.types.str;
              default = config.devenv.root;
            };
          };
          nix.enable = lib.mkEnableOption "Nix";
          shell.enable = lib.mkEnableOption "shell";
          # The other languages the module reads, for assay rule new's default language, and one it does not.
          typescript.enable = lib.mkEnableOption "TypeScript";
          python.enable = lib.mkEnableOption "Python";
          rust.enable = lib.mkEnableOption "Rust";
          scala.enable = lib.mkEnableOption "Scala";
          go.enable = lib.mkEnableOption "Go";
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

  # The module with the given rule packs' directory and default checks, and a repo's own definitions.
  evalModuleWith =
    packs: defaults: repo:
    (lib.evalModules {
      modules = [
        devenvStub
        (import ../devenv/module.nix { inherit defaults packs; })
        { _module.args.pkgs = pkgs; }
        repo
      ];
    }).config;
  # With the rule packs of assay's tests, test/packs/.
  evalModule = evalModuleWith ../test/packs;

  # The module with two default checks, `demo` and `tested` (which writes a coverage report and needs a tool).
  evalWith = evalModule (_: {
    demo = {
      exec = "true";
      fast = true;
    };
    tested = {
      exec = "run-tests";
      coverage = "$ASSAY_DIR/t.xml";
      packages = [ pkgs.hello ];
    };
  });

  # The module with assay's own default checks, the built-in ones.
  evalBuiltin = evalModule (import ../devenv/defaults.nix);
  builtinPlain = evalBuiltin { };
  builtinJavascript = evalBuiltin { languages.javascript.enable = true; };
  builtinPython = evalBuiltin { languages.python.enable = true; };
  builtinLoosened = evalBuiltin {
    assay.findings = {
      smells.function_complexity = {
        threshold = 25;
        reason = "parsers are one big match";
      };
      rules = {
        "python:S1481" = {
          enable = false;
          reason = "generated code";
        };
        "python:S3776".enable = true;
      };
    };
  };
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
  builtinDemoPack = evalBuiltin { assay.rulePacks = [ "demo" ]; };
  builtinTla = evalBuiltin { assay.checks.tla.enable = true; };
  languagesOn = evalWith {
    languages = {
      javascript.enable = true;
      typescript.enable = true;
      shell.enable = true;
      rust.enable = true;
      go.enable = true;
    };
  };

  # Whether the configuration file can be produced.
  evaluates = repo: (builtins.tryEval (evalWith repo).env.ASSAY_CONFIG).success;
  evaluatesBuiltin = repo: (builtins.tryEval (evalBuiltin repo).env.ASSAY_CONFIG).success;
  # With the packs assay ships, packs/.
  evaluatesShipped =
    repo: (builtins.tryEval (evalModuleWith ../packs (_: { }) repo).env.ASSAY_CONFIG).success;

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

  # The module with each language's default checks alone (devenv/languages/), for the languages a repo enables.
  withLanguages = evalModule (
    args: import ../devenv/languages/nix.nix args // import ../devenv/languages/bash.nix args
  );
  nixRepo = withLanguages { languages.nix.enable = true; };
  shellRepo = withLanguages { languages.shell.enable = true; };
  # Each check's name with what `assay check --list` shows of it: fast or not, and what it requires and covers.
  listed =
    config:
    lib.mapAttrs (_: c: {
      inherit (c)
        fast
        enable
        requires
        coverage
        ;
    }) config.assay.checks;
  fastCheck = {
    fast = true;
    enable = true;
    requires = null;
    coverage = null;
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
        "jscpd"
        "scc"
        "xmlstarlet"
        "hello"
        "diff-cover"
      ];
    "a repo that enables no language gets no language's check" =
      (withLanguages { }).assay.checks == { };
    "assay's defaults are the built-in checks and the enabled languages' checks" =
      let
        all =
          lib.attrNames
            (evalBuiltin {
              languages.nix.enable = true;
              languages.shell.enable = true;
            }).assay.checks;
      in
      lib.all (n: builtins.elem n all) (
        lib.attrNames builtinPlain.assay.checks
        ++ lib.attrNames nixRepo.assay.checks
        ++ lib.attrNames shellRepo.assay.checks
      );
    "Nix's defaults: nixfmt, statix, deadnix and nixf-tidy fast, nix flake check when flake.nix exists" =
      listed nixRepo == {
        nixfmt = fastCheck;
        statix = fastCheck;
        deadnix = fastCheck;
        nixf-tidy = fastCheck;
        nix-flake-check = {
          fast = false;
          enable = true;
          requires = "flake.nix";
          coverage = null;
        };
      };
    "bash's defaults: shellcheck and shfmt fast, bats with its coverage report under ASSAY_DIR" =
      listed shellRepo == {
        shellcheck = fastCheck;
        shfmt = fastCheck;
        bats = {
          fast = false;
          enable = true;
          requires = null;
          coverage = "$ASSAY_DIR/kcov/bats/cobertura.xml";
        };
      };
    "Nix's tools join the devenv, nixfmt and nixf among them" =
      lib.all (t: builtins.elem t (names nixRepo))
        [
          "assay-check-helpers"
          "nixfmt"
          "statix"
          "deadnix"
          "nixf"
          "jq"
        ];
    "bash's tools join the devenv, diff-cover among them" =
      lib.all (t: builtins.elem t (names shellRepo))
        [
          "assay-check-helpers"
          "ShellCheck"
          "shfmt"
          "bats"
          "diff-cover"
        ];
    "kcov joins the devenv where nixpkgs has it (Linux), and only there" =
      builtins.elem "kcov" (names shellRepo) == lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.kcov;
    "dropping the bats check's coverage is a loosening" =
      !(builtins.tryEval
        (withLanguages {
          languages.shell.enable = true;
          assay.checks.bats.coverage = null;
        }).env.ASSAY_CONFIG
      ).success;
    "without an enabled check that declares coverage, no diff-cover" =
      !(lib.elem "diff-cover" (names untested));
    "the preset check is built in, fast, and runs assay builtin preset" =
      builtinPlain.assay.checks.preset == {
        exec = "assay builtin preset";
        fast = true;
        enable = true;
        requires = null;
        coverage = null;
        reason = null;
      };
    "the built-in checks' tools join every repo's devenv, beside the CLI" =
      map lib.getName builtinPlain.packages == [
        "assay"
        "jscpd"
        "scc"
        "xmlstarlet"
        "actionlint"
        "ast-grep"
        "qlty"
        "gitleaks"
        "oxfmt"
      ];
    "radarlint joins the devenv of a repo with Python or Scala only" =
      lib.all (c: lib.elem "radarlint" (map lib.getName c.packages)) [
        builtinPython
        (evalBuiltin { languages.scala.enable = true; })
      ]
      && !(lib.elem "radarlint" (map lib.getName builtinJavascript.packages));
    "the findings check runs in the full run only" =
      builtinPlain.assay.checks.findings.exec == "assay builtin findings"
      && !builtinPlain.assay.checks.findings.fast;
    "raising a smell threshold without a reason fails evaluation" =
      !evaluatesBuiltin {
        assay.findings.smells.function_complexity.threshold = 25;
      };
    "raising a smell threshold without a reason fails an assertion" =
      builtins.any (a: !a.assertion)
        (evalBuiltin { assay.findings.smells.identical_code.threshold = 30; }).assertions;
    "raising a smell threshold with a reason evaluates" = evaluatesBuiltin {
      assay.findings.smells.function_complexity = {
        threshold = 25;
        reason = "why";
      };
    };
    "lowering a smell threshold is no loosening" = evaluatesBuiltin {
      assay.findings.smells.function_complexity.threshold = 10;
      assay.findings.smells.duplication.nodes_threshold = 40;
    };
    "turning a smell off without a reason fails evaluation" =
      !evaluatesBuiltin {
        assay.findings.smells.nested_control_flow.enable = false;
      };
    "raising duplication's nodes_threshold without a reason fails evaluation" =
      !evaluatesBuiltin {
        assay.findings.smells.duplication.nodes_threshold = 100;
      };
    "turning a radarlint rule off without a reason fails evaluation" =
      !evaluatesBuiltin {
        assay.findings.rules."python:S1481".enable = false;
      };
    "turning S3776 back on is no loosening" = evaluatesBuiltin {
      assay.findings.rules."python:S3776".enable = true;
    };
    "a rule key that is not Sonar's fails evaluation" =
      !evaluatesBuiltin {
        assay.findings.rules."python S1" = {
          enable = false;
          reason = "why";
        };
      };
    "the ast-grep check requires sgconfig.yml, until a rule pack is on" =
      builtinPlain.assay.checks.ast-grep.requires == "sgconfig.yml"
      && builtinDemoPack.assay.checks.ast-grep.requires == null;
    "a rule pack assay does not ship fails evaluation, and an assertion" =
      !evaluates { assay.rulePacks = [ "nope" ]; }
      && builtins.any (a: !a.assertion) (evalWith { assay.rulePacks = [ "nope" ]; }).assertions;
    "with the packs assay ships, none yet, no pack can be turned on" =
      evaluatesShipped { } && !evaluatesShipped { assay.rulePacks = [ "demo" ]; };
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
    "the tla check is off by default, runs in the full run only, and requires tla/*.cfg" =
      (listed builtinPlain).tla == {
        fast = false;
        enable = false;
        requires = "tla/*.cfg";
        coverage = null;
      }
      && builtinPlain.assay.checks.tla.exec == "assay builtin tla";
    "TLC joins the devenv only once the repo turns the tla check on" =
      !(lib.elem "tlaplus" (names builtinPlain)) && lib.elem "tlaplus" (names builtinTla);
    "a default check on by default keeps its tools when the repo turns it off" = lib.elem "gitleaks" (
      names (evalBuiltin {
        assay.checks.gitleaks = {
          enable = false;
          reason = "off for the test";
        };
      })
    );
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
  # assay's skills, each a directory of skills/, in name order.
  skillNames = lib.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../skills)
  );
  home = homeWith {
    programs.assay = {
      enable = true;
      rules = exampleRules;
      collect.database = "/fixture/metrics.db";
      collect.owners = [ "sample" ];
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
  scopedCommand = rule // {
    cwd = "main-checkout";
    workspaceRoot = "/workspace";
  };
  scopedPath = rule // {
    name = "p";
    on = "path";
    match = "main-checkout";
    workspaceRoot = "/workspace";
  };
  scopedHome = homeWith {
    programs.assay = {
      enable = true;
      rules = [
        scopedCommand
        scopedPath
      ];
    };
  };
  withoutGit = homeWith {
    programs.git.enable = lib.mkForce false;
    programs.assay.enable = true;
  };
  disabled = homeWith { programs.assay.rules = [ rule ]; };

  homeExpectations = {
    "a relative workspaceRoot fails evaluation" =
      !rulesEvaluate [ (scopedPath // { workspaceRoot = "relative"; }) ];
    "a scoped path glob fails evaluation" = !rulesEvaluate [ (scopedPath // { match = "*"; }) ];
    "a scoped cwd glob fails evaluation" = !rulesEvaluate [ (scopedCommand // { cwd = "*"; }) ];
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
    "a command match with a rule key takes a rule file's body only" =
      rulesEvaluate [
        (
          rule
          // {
            match = {
              rule.kind = "command";
              constraints.A.regex = "x";
            };
          }
        )
      ]
      && !rulesEvaluate [
        (
          rule
          // {
            match = {
              rule.kind = "command";
              message = "m";
            };
          }
        )
      ];
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
    "disabled, the module installs no skill" = lib.all (
      skill:
      !(disabled.config.home.file ? ".claude/skills/${skill}")
      && !(disabled.config.xdg.configFile ? "opencode/skills/${skill}")
    ) skillNames;
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
        nativeBuildInputs = import ./test-tools.nix { inherit pkgs; } ++ [ pkgs.coreutils ];
      }
      ''
        cp -r ${src} src
        chmod -R u+w src
        cd src
        patchShebangs assay.sh test/stub devenv/bin
        shellcheck assay.sh nix/rules-check.sh test/assert.bash test/helpers.bash test/devenv/helpers.bash test/stub/devenv devenv/bin/*
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
        jq -e 'del(.findings) == {version: 1,
          checks: {
            demo: {exec: "true", fast: true, enable: true, requires: null, coverage: null},
            tested: {exec: "run-tests", fast: false, enable: true, requires: null, coverage: "$ASSAY_DIR/t.xml"}},
          coverage: {newCode: 80}, loosenings: [], languages: [], rulePacks: {}}' \
          ${plain.env.ASSAY_CONFIG}
        # The enabled languages among assay's six, by ast-grep's names, sorted; Go is none of them.
        jq -e '.languages == ["bash", "javascript", "rust", "typescript"]' ${languagesOn.env.ASSAY_CONFIG}
        # A pack turned on is its directory, an ast-grep project.
        demo=$(jq -r '.rulePacks.demo' ${builtinDemoPack.env.ASSAY_CONFIG})
        [ "$(jq -c '.rulePacks | keys' ${builtinDemoPack.env.ASSAY_CONFIG})" = '["demo"]' ]
        test -f "$demo/sgconfig.yml" -a -f "$demo/rules/demo-no-which.yml"
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
        # The built-in checks give the configurations the bats suite runs.
        same() {
          jq -S . "$1" >a.json
          jq -S . "$2" >b.json
          diff a.json b.json || { echo "FAIL: $1 differs from $2" >&2; exit 1; }
        }
        same ${builtinPlain.env.ASSAY_CONFIG} ${../test/defaults/plain.json}
        same ${builtinJavascript.env.ASSAY_CONFIG} ${../test/defaults/javascript.json}
        same ${builtinFrontend.env.ASSAY_CONFIG} ${../test/defaults/javascript-frontend.json}
        same ${builtinPython.env.ASSAY_CONFIG} ${../test/defaults/python.json}
        # Turning the tla check on is no loosening.
        jq -e '.checks.tla.enable and .loosenings == []' ${builtinTla.env.ASSAY_CONFIG}
        # A loosening of the analyzer, with what it is; a tightening, none.
        jq -e '.loosenings == [
            {check: "findings", kind: "setting", reason: "parsers are one big match",
             what: "smells.function_complexity.threshold is 25, above qlty'"'"'s 18"},
            {check: "findings", kind: "setting", reason: "generated code", what: "rule python:S1481 is off"}]
          and .findings.smells.function_complexity == {enable: true, threshold: 25}
          and .findings.rules == {"python:S1481": false, "python:S3776": true, "scala:S3776": false}' \
          ${builtinLoosened.env.ASSAY_CONFIG}
        touch $out
      '';
}
// lib.optionalAttrs (lib.meta.availableOn pkgs.stdenv.hostPlatform qlty) {
  # The pinned static binary runs in the sandbox, which has no network, and every run has telemetry off.
  qlty =
    pkgs.runCommand "assay-qlty"
      {
        nativeBuildInputs = [ qlty ];
      }
      ''
        export HOME=$TMPDIR
        version=$(qlty --version)
        echo "$version"
        [[ $version == "qlty ${qlty.version} "* ]]
        grep -q "QLTY_TELEMETRY.*off" ${lib.getExe qlty}
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
        jq -e '[.rules[] | [.on, .workspaceRoot]] == [["command", "/workspace"], ["path", "/workspace"]]' \
          ${scopedHome.config.programs.assay.rulesFile}
        jq -S . ${../test/rules/example.json} >example.json
        diff rendered.json example.json || {
          echo "FAIL: the rendered rules differ from test/rules/example.json" >&2
          exit 1
        }
        # assay is on the user's PATH.
        test -x ${home.activationPackage}/home-path/bin/assay
        # Every skill, where Claude Code loads them and where OpenCode does, as the repo holds them, and nothing else.
        for dir in .claude/skills .config/opencode/skills; do
          [ "$(ls ${home.activationPackage}/home-files/$dir)" = ${lib.escapeShellArg (lib.concatStringsSep "\n" skillNames)} ]
          for skill in ${lib.escapeShellArgs skillNames}; do
            cmp ${home.activationPackage}/home-files/$dir/$skill/SKILL.md ${../skills}/$skill/SKILL.md
          done
        done
        units=${home.activationPackage}/home-files/.config/systemd/user
        grep -Fx 'OnCalendar=*-*-* 03:00:00' "$units/assay-collect.timer"
        grep -Fx 'ExecStart=${assayExe} collect --db /fixture/metrics.db' "$units/assay-collect.service"
        # The generated git config holds both hooks.
        gitconfig=${home.activationPackage}/home-files/.config/git/config
        for hook in commit-msg pre-push; do
          [ "$(git config -f "$gitconfig" "hook.assay-$hook.event")" = "$hook" ]
          command=$(git config -f "$gitconfig" "hook.assay-$hook.command")
          [ "$command" = "${assayExe} git-hook --rules ${rulesFile} $hook" ]
        done
        # With it as the global git config, in a throwaway repo: a commit whose message matches a commit-msg rule is
        # rejected with the rule's message, and the repo's own commit-msg hook still runs.
        export HOME=$PWD/home GIT_CONFIG_GLOBAL=$gitconfig GIT_CONFIG_NOSYSTEM=1
        export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
        export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
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
