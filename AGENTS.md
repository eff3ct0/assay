# assay

A repo's named checks, run the same way from pre-commit, `devenv test` and an agent's shell, and a machine's agent guard
and global git hooks: a bash CLI, with jq, awk and yq (`assay.sh`: `assay check`, `assay preset`, the built-in checks
that are its own code as `assay builtin <check>` (with the advisory comparison the languages' `osv-scanner` checks run,
`assay builtin osv-scanner`), `assay findings` over qlty, `assay new-code`, `assay rule new`, which
scaffolds an ast-grep rule, and the machine-level `assay guard` and `assay git-hook`, which read a rule list and match
command rules with ast-grep), each language's preset, every version of it (`preset/<language>/<version>/` and its
development dependencies, `<version>.dependencies`, which `preset/README.md` explains; today bash's and Python's), the
devenv module repos import (`devenv/`, the built-in checks in `devenv/defaults.nix`),
the opt-in rule packs of ast-grep rules (`packs/`, none yet), the skills agents load (`skills/`, `assay-rule` and
`assay-property`),
and a Nix flake (`nix/`) with the CLI's package, the `findings` check's tools, qlty and radarlint, each pinned on
purpose, the home-manager module that holds a machine's rule list and installs the skills (`nix/home-manager.nix`) and
the check builder that tests a rule list (`nix/rules-check.nix`, running `nix/rules-check.sh`). `README.md` says how a
repo and a machine use it, `docs/adoption.md` how an existing repo adopts it, and `GLOSSARY.md` holds the vocabulary.
assay adopts itself: its `devenv.yaml` imports its own module by path (`imports: [ ./devenv ]`), so each change is
checked by the version it ships, and it carries bash's preset (`.shellcheckrc`, `.assay-preset.json`). Each change
implements one of this repo's GitHub issues: read it, and the specifications it links, before changing behaviour.

## Related repos

- Depends on: none.
- Used by, named generically on purpose (assay is public, and the repos that use it may be private):
  - the repos that import its devenv module through a devenv input `assay` (`imports: [ assay/devenv ]`). They rely
    on the module's options (`assay.checks.<name>`, `assay.coverage`, `assay.findings`, `assay.seed`, `assay.rulePacks`
    and the packs' names), the `ASSAY_CONFIG`, `ASSAY_SEED` and `ASSAY_DIR` variables, the pre-commit hook and
    `enterTest` it adds, the built-in checks and the checks it turns on for the languages they enable, with the tools
    they bring into the devenv (actionlint, ast-grep, gitleaks, oxfmt, qlty, radarlint; nixfmt, statix, deadnix, nixf;
    shellcheck, shfmt, bats, kcov, diff-cover; ruff, pyright, vulture, osv-scanner), Python's checks' reliance on the
    project's venv (pytest, coverage.py, Hypothesis, deptry, import-linter) and the helpers they run (`assay-pytest`,
    `assay-deptry`), the opt-in `tla` check (`assay.checks.tla.enable`, which adds tlaplus18) and its
    `tla/<Name>.cfg` layout, the `ast-grep` check's opt-in (`sgconfig.yml`) and its placeholder marker, the `.qlty/` that
    `assay findings` writes and excludes through `.git/info/exclude`, the presets `assay preset` writes into them and
    merges later versions of, the development dependencies it adds with the project's package manager (uv), the record
    `.assay-preset.json`, and the output and exit codes of `assay check` (`--list` marking fast and off checks),
    `assay preset`, `assay builtin`, `assay findings` and `assay rule new` (the paths it creates, the layout it writes);
  - home-manager configurations, through the package, `homeManagerModules.default` and `lib.rulesCheck`. They rely on
    the module's options (`programs.assay.enable`, `package`, `rules` with its rule format, the read-only
    `rulesFile`), the global git hooks it registers in `programs.git.settings`, the `ASSAY_HITS_LOG` it sets and the
    skills it links into `~/.claude/skills` and OpenCode's skills directory (`/assay-rule`, `/assay-property`); on
    `assay guard`'s answers in Claude Code's hook JSON (an adapter, such as an OpenCode plugin, builds the same JSON),
    and its exit 1 that fails open; on `assay git-hook`'s exit codes and messages; on
    `lib.rulesCheck { pkgs, rules, assay }` and its examples' fixture; on `assay` re-executing itself through the
    repo's `devenv shell` when `ASSAY_CONFIG` is unset, and its exit 2 naming `docs/adoption.md` in a repo that has not
    adopted assay; and on the hits log's lines (`ASSAY_HITS_LOG`, `ASSAY_AGENT`).

## Run

- In this repo, or one that imports the module: `assay check [--fast] [--base <rev>] [<check>...]` or
  `assay check --list`, and `assay preset [<language>...]`, from the devenv (`devenv shell -- assay check`) or from
  outside it (plain `assay check`, or `nix run . -- check` here), which re-executes itself through `devenv shell`
  from the repo root.
- From this checkout without devenv: `ASSAY_CONFIG=<file> ./assay.sh check`, with git, jq and awk on the PATH;
  diff-cover for a check with `coverage`, and ast-grep and yq for the `ast-grep` check and `assay rule new`.
  Python's `assay preset` also uses yq for TOML and uv when dependencies change. The config has the shape
  `devenv/module.nix` writes; `test/helpers.bash` builds one by hand.
- One built-in check alone: `assay builtin <check>` (its `exec`), and the advisories on the change in lockfiles:
  `assay builtin osv-scanner [--base <rev>] <lockfile>...` (osv-scanner on the PATH); a change's new code as JSON:
  `assay new-code`; the analyzer's findings on the change: `assay findings [--base <rev>] [--sarif]`;
  an ast-grep rule's scaffold:
  `assay rule new <kebab-name> [--lang <lang>] [--from <file>:<line>[-<line>]]`.
- The guard and the git hooks, from anywhere: `echo '<hook event>' | assay guard --rules <file>` and
  `assay git-hook --rules <file> <hook> [<git's arguments>]`, with ast-grep on the PATH too; `test/rules/example.json`
  is a rule list. `bash nix/rules-check.sh <file>` runs a rule list's examples, with `assay` on the PATH.
- A rule pack's tests: `ast-grep test -c packs/<name>/sgconfig.yml --skip-snapshot-tests` (`test/packs/demo` is the
  pack the tests turn on).
- `nix build .#assay` builds the CLI; `nix build .#qlty .#radarlint` the `findings` check's tools.

## Test

- `devenv test`: what CI runs (`.github/workflows/check.yml`): the pre-commit hooks over all files, then
  `assay check`: the built-in checks, and Nix's and bash's, which assay enables: nixfmt, statix, deadnix, nixf-tidy,
  shellcheck, shfmt, `nix flake check`, and `bats` over every tracked `.bats` file (`test/` and `test/devenv/`)
  under kcov, with coverage of the branch's new lines. It needs the network and takes about three minutes.
  While working, `devenv shell -- assay check [--fast] [<check>...]`; `git commit` runs `assay check --fast`.
- `nix develop -c bats test`: the CLI against hand-written configurations in throwaway repos, with stubs for `devenv`,
  `uv` and `osv-scanner` (`test/stub/`); the base in `test/base.bats`, delegation in `test/delegate.bats`, the hits log
  in `test/hits.bats`, and `assay preset`, the `preset` check and the header line for a preset behind in `test/preset.bats`
  (with a synthetic later version of bash's preset), Python's preset, its development dependencies through the `uv`
  stub and the sections of other files that hold a tool's configuration in `test/preset-python.bats`, the advisory
  comparison in `test/osv-scanner.bats` (synthetic advisory records), new code in `test/new-code.bats`, the guard in
  `test/guard.bats`, the git hooks in `test/git-hook.bats`, and the check builder's script in `test/rules-check.bats`.
  The last three use `test/rules/example.json`, which `nix flake check` compares with the home-manager module's rendering
  of `test/rules/example.nix`. Each built-in check that is assay's own code has a file of its own
  (`test/agents-md.bats`, `test/ast-grep.bats`, `test/commit-trailers.bats`, `test/gitleaks.bats`,
  `test/suppressions.bats`, `test/findings.bats`, with real qlty and radarlint over `test/fixtures/findings/`,
  and `test/tla.bats`, with real TLC),
  `assay rule new` in `test/rule-new.bats`, every rule pack's tests and shape in `test/packs.bats` (over `packs/` and
  `test/packs/`), the skills' text in `test/skills.bats`, the built-in checks as the module configures them in
  `test/builtin.bats`, from `test/defaults/*.json`, which `nix flake check` compares with the module's, coverage of new
  code in `test/coverage.bats` (real diff-cover), and the language checks' helpers (`devenv/bin`) in
  `test/defaults.bats` (real kcov, bats, shfmt, nixf, and pytest, coverage.py and Hypothesis; deptry, which the
  flake's nixpkgs lacks, is a fake there). The tools it needs are `nix/test-tools.nix`, shared by the dev
  shell and the sandbox; the dev shell brings them from the flake's nixpkgs, older than the devenv's (oxfmt 0.45 against
  0.75, ast-grep 0.42 against 0.51): the suite passes with both. radarlint and TLC come from assay's own `devenv.nix`
  for the `bats` check. New behaviour gets a test there.
- `nix develop -c bats test/devenv`: the devenv module in throwaway repos that import a `git+file:` copy of this working
  tree, and assay's own adoption, through the `devenv` on the PATH (2.4.0 or later); the Nix and bash fixtures of the
  default checks in `test/devenv/defaults.bats`, bash's built by `assay preset bash`; Python's fixture in
  `test/devenv/python.bats`, built with `uv init --lib` and `assay preset python`; a rule pack and `assay rule new`
  in `test/devenv/rules.bats`; and the `tla` check off and on in `test/devenv/tla.bats`. The Python fixture uses real
  uv, PyPI and OSV for the clean scan, so the suite needs
  the network and takes a few minutes.
- `nix develop -c shellcheck assay.sh nix/rules-check.sh test/*.bash test/devenv/*.bash test/stub/* devenv/bin/*`
- `nix flake check`: shellcheck, `bats test`, the CLI's build, `qlty --version` with no network, the devenv module's
  evaluation against a stand-in for devenv's options (with `test/packs/` as its packs, and with the real
  `devenv/defaults.nix` and `packs/` too), and the home-manager module in a home built with the flake's `home-manager`
  input (its option checks, its git config driving a real commit, the skills it links, and `lib.rulesCheck` passing on
  the example list and failing on a broken one), all in `nix/checks.nix`, in the sandbox. It does not run `test/devenv`.
- kcov is `nix/kcov.nix`: nixpkgs' kcov 43 with upstream's fix for ANSI-C quoted strings, without which bats 1.14
  loses all coverage after its first `run`. Drop the patch once nixpkgs' kcov has it.

Keep everything generic: no machine names, people, secrets backends or absolute paths outside test fixtures.
