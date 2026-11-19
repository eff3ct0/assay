# assay

A repo's named checks, run the same way from pre-commit, `devenv test` and an agent's shell: a bash CLI, with jq and awk
(`assay.sh`: `assay check`, the built-in checks that are its own code as `assay builtin <check>`, and
`assay new-code`), the devenv module repos import (`devenv/`, the built-in checks in `devenv/defaults.nix`), and a Nix
flake with the CLI's package (`nix/`). `README.md` says how a repo uses it, `docs/adoption.md` how an existing repo
adopts it, and `GLOSSARY.md` holds the vocabulary. assay adopts itself: its `devenv.yaml` imports its own module by
path (`imports: [ ./devenv ]`), so each change is checked by the version it ships. Each change implements one of this
repo's GitHub issues: read it, and the specifications it links, before changing behaviour.

## Related repos

- Depends on: none.
- Used by, named generically on purpose (assay is public, and the repos that use it may be private):
  - the repos that import its devenv module through a devenv input `assay` (`imports: [ assay/devenv ]`). They rely
    on the module's options (`assay.checks.<name>`, `assay.coverage`, `assay.seed`), the `ASSAY_CONFIG`, `ASSAY_SEED`
    and `ASSAY_DIR` variables, the pre-commit hook and `enterTest` it adds, the built-in checks and the checks it
    turns on for the languages they enable, with the tools they bring into the devenv (actionlint, gitleaks, oxfmt;
    nixfmt, statix, deadnix, nixf; shellcheck, shfmt, bats, kcov, diff-cover), and the output and exit codes of
    `assay check` and `assay builtin`;
  - home-manager configurations, through the package and `homeManagerModules.default` (not exported yet: the guard's
    issue adds it). They rely on `assay` re-executing itself through the repo's `devenv shell` when `ASSAY_CONFIG` is
    unset, its exit 2 naming `docs/adoption.md` in a repo that has not adopted assay, and the hits log's lines
    (`ASSAY_HITS_LOG`, `ASSAY_AGENT`).

## Run

- In this repo, or one that imports the module: `assay check [--fast] [--base <rev>] [<check>...]` or
  `assay check --list`, from the devenv (`devenv shell -- assay check`) or from outside it (plain `assay check`, or
  `nix run . -- check` here), which re-executes itself through `devenv shell` from the repo root.
- From this checkout without devenv: `ASSAY_CONFIG=<file> ./assay.sh check`, with git, jq and awk on the PATH (and
  diff-cover for a check with `coverage`). The file has the shape `devenv/module.nix` writes; `test/helpers.bash`
  builds one by hand.
- One built-in check alone: `assay builtin <check>` (its `exec`); a change's new code as JSON: `assay new-code`.
- `nix build .#assay` builds the CLI.

## Test

- `devenv test`: what CI runs (`.github/workflows/check.yml`): the pre-commit hooks over all files, then
  `assay check`: the built-in checks, and Nix's and bash's, which assay enables: nixfmt, statix, deadnix, nixf-tidy,
  shellcheck, shfmt, `nix flake check`, and `bats` over every tracked `.bats` file (`test/` and `test/devenv/`)
  under kcov, with coverage of the branch's new lines. It needs the network the first time and takes about three minutes. While
  working, `devenv shell -- assay check [--fast] [<check>...]`; `git commit` runs `assay check --fast`.
- `nix develop -c bats test`: the CLI against hand-written configurations in throwaway repos, with a stub `devenv`
  (`test/stub/devenv`); the base of the change in `test/base.bats`, delegation in `test/delegate.bats`, the hits log
  in `test/hits.bats`, new code in `test/new-code.bats`, each built-in check that is assay's own code in a file of its
  own (`test/agents-md.bats`, `test/commit-trailers.bats`, `test/gitleaks.bats`, `test/suppressions.bats`), the
  built-in checks as the module configures them in `test/builtin.bats`, from `test/defaults/*.json`, which
  `nix flake check` compares with the module's, coverage of new code in `test/coverage.bats` (real diff-cover), and
  the language checks' helpers (`devenv/bin`) in `test/defaults.bats` (real kcov, bats, shfmt, nixf). The tools it
  needs are `nix/test-tools.nix`, shared by the dev shell and the sandbox; the dev shell brings them from the flake's
  nixpkgs, older than the devenv's (oxfmt 0.45 against 0.75): the suite passes with both. New behaviour gets a test
  there.
- `nix develop -c bats test/devenv`: the devenv module in throwaway repos that import a `git+file:` copy of this
  working tree, and assay's own adoption, through the `devenv` on the PATH (2.4.0 or later); the Nix and bash
  fixtures of the default checks in `test/devenv/defaults.bats`. It needs the network the first time and takes a few
  minutes.
- `nix develop -c shellcheck assay.sh test/helpers.bash test/devenv/helpers.bash test/stub/devenv devenv/bin/*`
- `nix flake check`: shellcheck, `bats test`, the CLI's build and the module's evaluation against a stand-in for
  devenv's options (`nix/checks.nix`), with the real `devenv/defaults.nix` too, in the sandbox. It does not run
  `test/devenv`.
- kcov is `nix/kcov.nix`: nixpkgs' kcov 43 with upstream's fix for ANSI-C quoted strings, without which bats 1.14
  loses all coverage after its first `run`. Drop the patch once nixpkgs' kcov has it.

Keep everything generic: no machine names, people, secrets backends or absolute paths outside test fixtures.
