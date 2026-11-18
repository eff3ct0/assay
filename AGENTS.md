# assay

A repo's named checks, run the same way from pre-commit, `devenv test` and an agent's `devenv shell`: a bash + jq
CLI (`assay.sh`, `assay check`), the devenv module repos import (`devenv/`), and a Nix flake with the CLI's package
(`nix/`). `README.md` says how a repo uses it. Each change implements one of this repo's GitHub issues: read it, and
the specifications it links, before changing behaviour.

## Related repos

- Depends on: none.
- Used by: the repos that import its devenv module through a devenv input `assay` (`imports: [ assay/devenv ]`),
  named generically on purpose: assay is public, and the repos that use it may be private. What they rely on is the
  module's options (`assay.checks.<name>`, `assay.seed`), the `ASSAY_CONFIG` and `ASSAY_SEED` variables, the
  pre-commit hook and `enterTest` it adds, and `assay check`'s output and exit codes.

## Run

- In a repo that imports the module: `devenv shell -- assay check [--fast] [--base <rev>] [<check>...]`, or
  `assay check --list`.
- From this checkout: `ASSAY_CONFIG=<file> ./assay.sh check`, with git and jq on the PATH. The file has the shape
  `devenv/module.nix` writes; `test/helpers.bash` builds one by hand.
- `nix build .#assay` builds the CLI.

## Test

- `nix develop -c bats test`: the CLI against hand-written configurations in throwaway repos; the base of the change
  in `test/base.bats`. New behaviour gets a test there.
- `nix develop -c bats test/devenv`: the devenv module in throwaway repos that import a `git+file:` copy of this
  working tree, through the `devenv` on the PATH (2.4.0 or later). It needs the network the first time and takes
  about a minute.
- `nix develop -c shellcheck assay.sh test/helpers.bash test/devenv/helpers.bash`
- `nix flake check`: shellcheck, `bats test`, the CLI's build and the module's evaluation against a stand-in for
  devenv's options (`nix/checks.nix`), in the sandbox. It does not run `test/devenv`.

Keep everything generic: no machine names, people, secrets backends or absolute paths outside test fixtures.
