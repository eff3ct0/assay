# assay's home-manager module, flake.nix's homeManagerModules.default: the CLI on the user's PATH, the machine's rule
# list (programs.assay.rules) rendered into the one JSON file that `assay guard` and `assay git-hook` read with
# --rules, the global git hooks registered in the user's git config, the hits log's path, and assay's skills
# (skills/) where Claude Code and OpenCode load them. assay ships no rules: a machine's live in its own configuration. A harness's hooks (Claude Code's managed settings, an OpenCode plugin)
# call `assay guard --rules <rulesFile>`; wiring them is the machine's.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.assay;
  inherit (lib) mkOption types;

  # assay's skills: each directory of skills/, holding its SKILL.md.
  skills = lib.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../skills)
  );
  # skillFiles <directory>: each skill, linked at <directory>/<name>.
  skillFiles =
    dir:
    lib.listToAttrs (
      map (name: lib.nameValuePair "${dir}/${name}" { source = ../skills + "/${name}"; }) skills
    );

  # What an example of each kind of rule holds. A string stands for the first field; a stop example has none.
  exampleFields = {
    command = {
      command = "string";
      cwd = "string";
      files = "set";
    };
    path = {
      path = "string";
      cwd = "string";
    };
    commit-msg.message = "string";
    pre-push = {
      ref = "string";
      files = "set";
    };
    stop = {
      uncommitted = "bool";
      unpushed = "bool";
      remote = "bool";
    };
  };
  stringField = {
    command = "command";
    path = "path";
    commit-msg = "message";
    pre-push = "ref";
  };
  # A field an object example must have.
  requiredField = {
    command = "command";
    path = "path";
    commit-msg = "message";
  };
  # The keys of an ast-grep rule file's body that a command rule's match may hold, beside the rule itself.
  ruleBodyKeys = [
    "rule"
    "constraints"
    "utils"
    "transform"
  ];
  predicates = {
    pre-push = [
      "agent-branch"
      "agents-md"
    ];
    stop = [ "unsaved-work" ];
  };

  exampleProblems =
    rule: kind: n: ex:
    let
      where = "rule ${rule.name}, ${kind} example ${toString n}";
      fields = exampleFields.${rule.on};
    in
    if builtins.isString ex then
      lib.optional (!(stringField ? ${rule.on})) "${where}: a ${rule.on} example is an attribute set"
    else
      lib.concatLists (
        lib.mapAttrsToList (
          k: v:
          if !(fields ? ${k}) then
            [ "${where}: ${rule.on} examples have no field ${k}" ]
          else if builtins.typeOf v != fields.${k} then
            [ "${where}: ${k} must be a ${fields.${k}}" ]
          else if k == "files" && !(lib.all (c: c == null || builtins.isString c) (lib.attrValues v)) then
            [ "${where}: each file holds a string, or null" ]
          else
            [ ]
        ) ex
      )
      ++ lib.optional (
        requiredField ? ${rule.on} && !(ex ? ${requiredField.${rule.on}})
      ) "${where}: no ${requiredField.${rule.on}}";

  ruleProblems =
    rule:
    let
      where = "rule ${rule.name}";
    in
    lib.optional (
      rule.on == "command" && !builtins.isAttrs rule.match
    ) "${where}: a command rule's match is an ast-grep rule, an attribute set"
    ++
      lib.optional
        (
          rule.on == "command"
          && builtins.isAttrs rule.match
          && rule.match ? rule
          && removeAttrs rule.match ruleBodyKeys != { }
        )
        "${where}: a match with a rule key is a rule file's body: ${lib.concatStringsSep ", " ruleBodyKeys} only"
    ++ lib.optional (
      rule.on != "command" && !builtins.isString rule.match
    ) "${where}: a ${rule.on} rule's match is a string"
    ++ lib.optional (
      predicates ? ${rule.on} && !(lib.elem rule.match predicates.${rule.on})
    ) "${where}: a ${rule.on} rule's match is one of ${lib.concatStringsSep ", " predicates.${rule.on}}"
    ++ lib.optional (rule.on != "command" && rule.cwd != null) "${where}: only a command rule has a cwd"
    ++ lib.optional (
      rule.on != "command" && rule.fileContent != null
    ) "${where}: only a command rule has a fileContent"
    ++ lib.concatLists (lib.imap1 (exampleProblems rule "deny") rule.deny)
    ++ lib.concatLists (lib.imap1 (exampleProblems rule "allow") rule.allow);

  names = map (r: r.name) cfg.rules;
  duplicates = lib.unique (lib.filter (n: lib.count (m: m == n) names > 1) names);
  problems =
    lib.concatMap ruleProblems cfg.rules
    ++ map (n: "two or more rules are named ${n}: a rule's name is its stable id") duplicates;
  problemsMessage = ''
    programs.assay.rules:
    ${lib.concatMapStringsSep "\n" (p: "  - ${p}") problems}'';

  normalise = on: ex: if builtins.isString ex then { ${stringField.${on}} = ex; } else ex;
  render = rule: {
    inherit (rule)
      name
      on
      match
      message
      note
      who
      cwd
      fileContent
      ;
    deny = map (normalise rule.on) rule.deny;
    allow = map (normalise rule.on) rule.allow;
  };

  # What --rules reads. It cannot be produced while the list has a problem, whatever asks for it.
  rulesFile =
    if problems != [ ] then
      throw problemsMessage
    else
      pkgs.writeText "assay-rules.json" (
        builtins.toJSON {
          version = 1;
          rules = map render cfg.rules;
        }
      );

  example = types.either types.str (types.attrsOf types.anything);

  ruleModule = {
    options = {
      name = mkOption {
        type = types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*";
        description = "The rule's stable id, which the hits log records on each denial, block or rejection.";
      };
      on = mkOption {
        type = types.enum [
          "command"
          "path"
          "commit-msg"
          "pre-push"
          "stop"
        ];
        description = ''
          What the rule judges: `command`, the Bash tool's command (`assay guard`); `path`, the path an Edit, Write
          or NotebookEdit writes (`assay guard`); `commit-msg`, a commit's message (`assay git-hook`); `pre-push`, the
          refs a push sends (`assay git-hook`); `stop`, the session's worktree when a turn ends (`assay guard`).
        '';
      };
      match = mkOption {
        type = types.either types.nonEmptyStr (types.attrsOf types.anything);
        description = ''
          For `command`, an ast-grep rule for bash (the value of a rule file's `rule:`), or a rule file's body
          (`rule` with `constraints`, `utils`, `transform`), matched against the command's structure. For `path`, a
          glob or `main-checkout`. For `commit-msg`, a regex in jq's syntax. For `pre-push`,
          `agent-branch` or `agents-md`. For `stop`, `unsaved-work`.
        '';
      };
      message = mkOption {
        type = types.strMatching "[^\n]+";
        description = "One line: what is wrong and what to do instead.";
      };
      note = mkOption {
        type = types.str;
        default = "";
        description = "Why, Fix, Not a fix, and the closing line; shown after the message.";
      };
      who = mkOption {
        type = types.enum [
          "agents"
          "everyone"
        ];
        default = "agents";
        description = "`agents`: the rule runs only when ASSAY_AGENT is non-empty. `everyone`: always.";
      };
      cwd = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        example = "main-checkout";
        description = ''
          A command rule's cwd: a glob or `main-checkout`; the rule runs only when the event's cwd matches it.
        '';
      };
      fileContent = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        description = ''
          A command rule's regex over a file the command names: a match that binds the ast-grep metavariable `$FILE`
          counts only when the file it names holds text matching it (`gh pr create --body-file`).
        '';
      };
      deny = mkOption {
        type = types.nonEmptyListOf example;
        description = "Examples the rule denies: the corrected command, path, message, push or session state.";
      };
      allow = mkOption {
        type = types.nonEmptyListOf example;
        description = "Examples the rule allows: the fix, plus a near miss.";
      };
    };
  };
in
{
  options.programs.assay = {
    enable = lib.mkEnableOption "assay's machine-level part: the agent guard and the global git hooks";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.assay;
      defaultText = lib.literalExpression "assay.packages.\${system}.assay";
      description = "The assay package.";
    };
    rules = mkOption {
      type = types.listOf (types.submodule ruleModule);
      default = [ ];
      description = ''
        The machine's rule list, which `assay guard` and `assay git-hook` read. Several definitions merge. A broken
        list fails the configuration's evaluation: every rule has a one-line message and at least one deny and one
        allow example, which `assay.lib.rulesCheck` feeds to the entrypoints.
      '';
    };
    rulesFile = mkOption {
      type = types.path;
      readOnly = true;
      default = rulesFile;
      defaultText = lib.literalMD "the rule list rendered as JSON";
      description = "The rendered rule list, the file given with `--rules`.";
    };
  };

  config = lib.mkIf cfg.enable {
    home = {
      packages = [ cfg.package ];
      # Only this machine records hits: CI and other machines leave ASSAY_HITS_LOG unset.
      sessionVariables.ASSAY_HITS_LOG = lib.mkDefault "${config.xdg.stateHome}/assay/hits.jsonl";
      # The skills, where Claude Code loads a user's skills (which `/<name>` also invokes) and where OpenCode does
      # (below). OpenCode reads ~/.claude/skills too, and lists a skill found in both places once.
      file = skillFiles ".claude/skills";
    };
    xdg.configFile = skillFiles "opencode/skills";

    # Config-based hooks (git 2.54): they run in every repo beside the repo's own hooks and leave no trace in it.
    programs.git.settings.hook = lib.listToAttrs (
      map
        (
          hook:
          lib.nameValuePair "assay-${hook}" {
            event = hook;
            command = "${lib.getExe cfg.package} git-hook --rules ${cfg.rulesFile} ${hook}";
          }
        )
        [
          "commit-msg"
          "pre-push"
        ]
    );

    warnings = lib.optional (!config.programs.git.enable) ''
      programs.assay: the global git hooks live in home-manager's git configuration, which programs.git.enable is
      off for: no commit or push runs assay's rules.'';

    assertions = [
      {
        assertion = problems == [ ];
        message = problemsMessage;
      }
    ];
  };
}
