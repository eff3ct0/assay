# assay

A repo's named checks, run the same way from pre-commit, `devenv test` and an agent's shell, and a machine's agent
guard and global git hooks: a bash CLI, with jq and awk (`assay.sh`: `assay check`, the built-in checks that are its own
code as `assay builtin <check>`, `assay findings` over qlty, `assay new-code`, and the machine-level `assay guard` and
`assay git-hook`, which read a rule list and match command rules with ast-grep), the devenv module repos import
(`devenv/`, the built-in checks in `devenv/defaults.nix`), and a Nix flake (`nix/`) with the CLI's package, the
`findings` check's tools, qlty and radarlint, each pinned on purpose, the home-manager module that holds a machine's
rule list (`nix/home-manager.nix`) and the check builder that tests one (`nix/rules-check.nix`, running
`nix/rules-check.sh`). `README.md` says how a repo and a machine use it, `docs/adoption.md` how an existing repo adopts
it, and `GLOSSARY.md` holds the vocabulary. assay adopts itself: its `devenv.yaml` imports its own module by
path (`imports: [ ./devenv ]`), so each change is checked by the version it ships. Each change implements one of this
repo's GitHub issues: read it, and the specifications it links, before changing behaviour.

## Related repos

- Depends on: none.
- Used by, named generically on purpose (assay is public, and the repos that use it may be private):
  - the repos that import its devenv module through a devenv input `assay` (`imports: [ assay/devenv ]`). They rely
    on the module's options (`assay.checks.<name>`, `assay.findings`, `assay.seed`), the `ASSAY_CONFIG` and
    `ASSAY_SEED` variables, the pre-commit hook and `enterTest` it adds, the built-in checks with the tools they bring
    into the devenv (actionlint, gitleaks, oxfmt, qlty, radarlint), the `.qlty/` that `assay findings` writes and
    excludes through `.git/info/exclude`, and the output and exit codes of `assay check`, `assay builtin` and
    `assay findings`;
  - home-manager configurations, through the package, `homeManagerModules.default` and `lib.rulesCheck`. They rely on
    the module's options (`programs.assay.enable`, `package`, `rules` with its rule format, the read-only
    `rulesFile`), the global git hooks it registers in `programs.git.settings` and the `ASSAY_HITS_LOG` it sets; on
    `assay guard`'s answers in Claude Code's hook JSON (an adapter, such as an OpenCode plugin, builds the same JSON),
    and its exit 1 that fails open; on `assay git-hook`'s exit codes and messages; on
    `lib.rulesCheck { pkgs, rules, assay }` and its examples' fixture; on `assay` re-executing itself through the
    repo's `devenv shell` when `ASSAY_CONFIG` is unset, and its exit 2 naming `docs/adoption.md` in a repo that has not
    adopted assay; and on the hits log's lines (`ASSAY_HITS_LOG`, `ASSAY_AGENT`).

## Run

- In this repo, or one that imports the module: `assay check [--fast] [--base <rev>] [<check>...]` or
  `assay check --list`, from the devenv (`devenv shell -- assay check`) or from outside it (plain `assay check`, or
  `nix run . -- check` here), which re-executes itself through `devenv shell` from the repo root.
- From this checkout without devenv: `ASSAY_CONFIG=<file> ./assay.sh check`, with git, jq and awk on the PATH. The file
  has the shape `devenv/module.nix` writes; `test/helpers.bash` builds one by hand.
- One built-in check alone: `assay builtin <check>` (its `exec`); a change's new code as JSON: `assay new-code`; the
  analyzer's findings on the change: `assay findings [--base <rev>] [--sarif]`.
- The guard and the git hooks, from anywhere: `echo '<hook event>' | assay guard --rules <file>` and
  `assay git-hook --rules <file> <hook> [<git's arguments>]`, with ast-grep on the PATH too; `test/rules/example.json`
  is a rule list. `bash nix/rules-check.sh <file>` runs a rule list's examples, with `assay` on the PATH.
- `nix build .#assay` builds the CLI; `nix build .#qlty .#radarlint` the `findings` check's tools.

## Test

- `devenv test`: what CI runs (`.github/workflows/check.yml`): the pre-commit hooks over all files, then
  `assay check`, whose `bats` check is the suite in `test/`. While working, `devenv shell -- assay check [--fast]
  [<check>...]`; `git commit` runs `assay check --fast`.
- `nix develop -c bats test`: the CLI against hand-written configurations in throwaway repos, with a stub `devenv`
  (`test/stub/devenv`); the base of the change in `test/base.bats`, delegation in `test/delegate.bats`, the hits log
  in `test/hits.bats`, new code in `test/new-code.bats`, the guard in `test/guard.bats`, the git hooks in
  `test/git-hook.bats`, the check builder's script in `test/rules-check.bats` (the last three over the example rule
  list `test/rules/example.json`, which `nix flake check` compares with the home-manager module's rendering of
  `test/rules/example.nix`), each built-in check that is assay's own code in a file of its own
  (`test/agents-md.bats`, `test/commit-trailers.bats`, `test/gitleaks.bats`, `test/suppressions.bats`,
  `test/findings.bats`, with real qlty and radarlint over `test/fixtures/findings/`), and the built-in checks as the
  module configures them in `test/builtin.bats`, from `test/defaults/*.json`, which `nix flake check` compares with
  the module's. The dev shell brings the built-in checks' tools and ast-grep from the flake's nixpkgs, older than the
  devenv's (oxfmt 0.45 against 0.75, ast-grep 0.42 against 0.51): the suite passes with both; radarlint, which the
  module brings only to repos with Python or Scala, comes from assay's own `devenv.nix` for the `bats` check. New
  behaviour gets a test there.
- `nix develop -c bats test/devenv`: the devenv module in throwaway repos that import a `git+file:` copy of this
  working tree, and assay's own adoption, through the `devenv` on the PATH (2.4.0 or later). It needs the network the
  first time and takes about a minute.
- `nix develop -c shellcheck assay.sh nix/rules-check.sh test/helpers.bash test/devenv/helpers.bash test/stub/devenv`
- `nix flake check`: shellcheck, `bats test`, the CLI's build, `qlty --version` with no network, the devenv module's
  evaluation against a stand-in for devenv's options, and the home-manager module in a home built with the flake's
  `home-manager` input (its option checks, its git config driving a real commit, and `lib.rulesCheck` passing on the
  example list and failing on a broken one), all in `nix/checks.nix`, in the sandbox. It does not run `test/devenv`.

Keep everything generic: no machine names, people, secrets backends or absolute paths outside test fixtures.
