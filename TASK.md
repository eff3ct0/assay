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
  `packages`. Its steps run in order, each only when the one before passed:
  1. a plain text search (`git grep --untracked`, the files git sees) for `ast-grep-ignore` outside the rule
     directories, and for the scaffold's placeholders (`<fill in:`) inside them;
  2. `ast-grep test --skip-snapshot-tests`, for the repo's `sgconfig.yml` and for each pack it turns on;
  3. `ast-grep scan`, the same.
     The rule directories (`ruleDirs`, `utilDirs`, `testConfigs[].testDir`, `snapshotDir`) come from `sgconfig.yml`,
     read with yq (yq-go), which joins the package's own tools (`assay_tools`), the flake's dev shell, assay's devenv
     and the flake checks' inputs.
- **Placeholders** are the text `<fill in: …>`, quoted in YAML. The check's text search finds them, so a
  half-written rule fails `assay check` (ast-grep itself would accept a placeholder pattern).
- **`assay rule new <kebab-name> [--lang <lang>] [--from <file>:<line>[-<line>]]`**: delegated like `check`. The
  delegating assay now enters the caller's directory inside the devenv before running the repo's assay, so `--from`'s
  path is relative to the caller's directory (every other subcommand moves to the repo root itself, as before).
  - With `sgconfig.yml` missing, it writes one with relative paths (`rules`, `rule-tests`). With one present, it
    writes into its first `ruleDirs` entry and its first `testConfigs[].testDir`; exit 2 when it names none.
  - Exit 1 when `<ruleDir>/<name>.yml` or `<testDir>/<name>-test.yml` exists, or a rule file under a rule directory
    has `id: <name>`.
  - `--lang` defaults to the language of `--from`'s file (by extension, a shell shebang too), among assay's six
    languages and their kin (`typescript`, `tsx`, `javascript`, `python`, `rust`, `scala`, `nix`, `bash`), else to
    the repo's single enabled language. The devenv module writes the enabled languages into the configuration as
    `languages`: `javascript` and `typescript` give `typescript`, `shell` gives `bash`, `python`, `rust`, `scala`
    and `nix` their own name.
  - `--from`'s lines are dedented and written as a YAML block scalar, or as a JSON string when the first line still
    starts with whitespace or a line holds a control character other than a tab.
  - Every file it writes passes the built-in `oxfmt` check.
- **Rule packs**: `packs/<name>/` in assay, each an ast-grep project of its own (`sgconfig.yml`, `rules/`,
  `rule-tests/`); `packs/README.md` holds the layout. A repo turns packs on with `assay.rulePacks = [ "<name>" ];`;
  an unknown name fails evaluation. The module writes `rulePacks` (name → directory) into the configuration. The
  module takes the packs directory as an argument (`packs`), so the flake checks run it over `test/packs/`, and the
  devenv tests copy `test/packs/demo` into a copy of assay's `packs/`.
- **The skills**: `skills/<name>/SKILL.md` in assay, every one installed by the home-manager module at
  `~/.claude/skills/<name>/` (Claude Code, and OpenCode's Claude compatibility) and
  `$XDG_CONFIG_HOME/opencode/skills/<name>/` (OpenCode's own). Checked with OpenCode 2.3.0 in a throwaway HOME: it
  loads skills from `~/.claude/skills/`, `~/.agents/skills/` and `~/.config/opencode/skill(s)/`, and lists a skill
  found in both `~/.claude/skills/` and `~/.config/opencode/skills/` once.
- **Seams under test**: the CLI in bats (`test/rule-new.bats`, `test/ast-grep.bats`, `test/packs.bats`, the skill's
  text in `test/skills.bats`); the devenv module's configuration and the home-manager module's files in
  `nix/checks.nix`; a real devenv in `test/devenv/module.bats`.

## Remaining steps

1. The `ast-grep` check: assay.sh, defaults.nix, test/defaults/*.json, test/ast-grep.bats, the lists in
   test/builtin.bats and test/devenv/module.bats.
2. `languages` and `rulePacks` in the module and the configuration; nix/checks.nix.
3. `assay rule new`, test/rule-new.bats; delegation from a subdirectory in test/delegate.bats.
4. Rule packs: packs/README.md, test/packs/demo, test/packs.bats.
5. The `assay-rule` skill, its installation in nix/home-manager.nix, nix/checks.nix, test/skills.bats.
6. test/devenv: a pack and `assay rule new` in a real devenv.
7. README.md, AGENTS.md, GLOSSARY.md.
8. The full suite (`nix flake check`, `bats test/devenv`, `devenv test`), the code review, the critic, the pull
   request. Remove this file once the last critic passes.
