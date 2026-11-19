# Task: issue #13

## The request, verbatim

> /mattpocock-skills:implement https://github.com/eff3ct0/assay/issues/13
>
> Toma tú cada decisión con tu recomendación, sin esperarme. Sigue ~/git/AGENTS.md: worktree de grove en una rama
> agent/, y el crítico te toca a ti, porque tú eres el autor de este cambio. Termina con un pull request que diga
> "Closes https://github.com/eff3ct0/assay/issues/13" y no lo mergees.

Issue #13 ("`assay rule new`, the `ast-grep` check, rule packs and the `assay-rule` skill") holds the specification
and the acceptance criteria; it links nixos-config#51, #50, #56 and #58, whose resolutions are in their comments.

## Decisions

- **The `ast-grep` check** is a built-in, fast check, `assay builtin ast-grep`, `requires = "sgconfig.yml"` (null
  when the repo turns a rule pack on: a pack alone is an opt-in too). ast-grep joins the devenv through the check's
  `packages`. Its three steps run in order, each whatever the one before found, so one run shows every failure; only
  a placeholder ends the check after the first:
  1. a plain text search (`git grep --untracked`, the files git sees) for `ast-grep-ignore` outside the rule
     directories, and for the scaffold's placeholders (`<fill in:`) inside them;
  2. `ast-grep test --skip-snapshot-tests`, for the repo's `sgconfig.yml` and for each pack it turns on;
  3. `ast-grep scan`, the same.

  The rule directories are `sgconfig.yml`'s `ruleDirs`, `utilDirs` and `testConfigs[].testDir`, read with yq (yq-go),
  which joins the package's own tools (`assay_tools`), `nix/test-tools.nix` and assay's devenv.

- **Placeholders** are the text `<fill in: …>`, quoted in YAML. The check's text search finds them, so a
  half-written rule fails `assay check` (ast-grep itself would accept a placeholder pattern).
- **`assay rule new <kebab-name> [--lang <lang>] [--from <file>:<line>[-<line>]]`**: delegated like `check`. The
  delegating assay now enters the caller's directory inside the devenv before running the repo's assay, so `--from`'s
  path is relative to the caller's directory (every other subcommand moves to the repo root itself, as before), and
  the paths it prints are relative to that directory too.
  - With `sgconfig.yml` missing, it writes one with relative paths (`rules`, `rule-tests`). With one present, it
    writes into its first `ruleDirs` entry and its first `testConfigs[].testDir`; exit 2 when it names none.
  - Exit 1 when `<ruleDir>/<name>.yml` or `<testDir>/<name>-test.yml` exists, or a YAML file under a directory
    `sgconfig.yml` names has `id: <name>`.
  - `--lang` defaults to the language ast-grep parses `--from`'s file as (`ast-grep run -p '$A' --json=stream`, the
    first match's `language`, lowercased), or `bash` for an extensionless script with a shell shebang, else to the
    repo's single enabled language. The devenv module writes the enabled languages into the configuration as
    `languages`, by devenv's names except `shell`, which is `bash` (`javascript` stays `javascript`: an ast-grep rule
    for TypeScript does not read `.js` files).
  - `--from`'s lines are dedented and written as a YAML block scalar, or as a JSON string when the first line still
    starts with whitespace or a line holds a control character other than a tab.
  - Every file it writes passes the built-in `oxfmt` check.
- **Rule packs**: `packs/<name>/` in assay, each an ast-grep project of its own (`sgconfig.yml`, `rules/`,
  `rule-tests/`); `packs/README.md` holds the layout. A repo turns packs on with `assay.rulePacks = [ "<name>" ];`;
  an unknown name fails evaluation. The module writes `rulePacks` (name → directory) into the configuration, and takes
  the packs directory as an argument (`packs`), so the flake checks run it over `test/packs/`, and the devenv tests
  copy `test/packs/demo` into a copy of assay's `packs/`. A pack's rules take no exception from a repo: a repo that
  cannot clean up every existing occurrence keeps its own copy of the rule, with `ignores`, until it can.
- **The skills**: `skills/<name>/SKILL.md` in assay, every one installed by the home-manager module at
  `~/.claude/skills/<name>/` and `$XDG_CONFIG_HOME/opencode/skills/<name>/`. Checked in throwaway homes:
  - OpenCode 2.3.0 loads skills from `~/.claude/skills/`, `~/.agents/skills/` and `~/.config/opencode/skill(s)/`, and
    lists a skill found in both `~/.claude/skills/` and `~/.config/opencode/skills/` once;
  - Claude Code 2.1.325, with the skill symlinked into the Nix store in its user skills directory, logs "Loaded 1
    unique skills (… user: 1 …)" and "1 skill dir commands": `/assay-rule` is a command.
- **Seams under test**: the CLI in bats (`test/rule-new.bats`, `test/ast-grep.bats`, `test/packs.bats`, the skill's
  text in `test/skills.bats`, `test/projects/no-eval` the ast-grep project they copy); the devenv module's
  configuration and the home-manager module's files in `nix/checks.nix`; a real devenv in `test/devenv/rules.bats`.
- **Coverage of new code**: `devenv test`'s `bats` check counts the lines inside `assay.sh`'s multi-line jq and awk
  strings as uncovered new code (issue #20); the real lines are covered by tests so that the change clears 80%.

## Remaining steps

The branch was rebased onto `ab03c18` (#21: Nix and bash default checks, kcov, shfmt over the suite), its base
commit now. Done: everything the issue asks for, and the code review's fixes.

1. The full suite: `nix flake check`, `nix develop -c bats test/devenv`, `devenv test`.
2. The critic, then the pull request ("Closes https://github.com/eff3ct0/assay/issues/13"), not merged. Remove this
   file once the last critic passes.
