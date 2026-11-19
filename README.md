# assay

A repo's named checks, declared once in its devenv and run the same way from pre-commit, `devenv test` and an agent's
`devenv shell`.

## In a repo

An existing repo adopts assay in a change of its own, before other work: [docs/adoption.md](docs/adoption.md).

`devenv.yaml`:

```yaml
inputs:
  nixpkgs:
    url: github:cachix/devenv-nixpkgs/rolling
  # devenv 2.4.0 needs it here; from 2.4.1 assay's own devenv/devenv.yaml brings it.
  git-hooks:
    url: github:cachix/git-hooks.nix
    inputs:
      nixpkgs:
        follows: nixpkgs
  assay:
    url: github:eff3ct0/assay
    flake: false
imports:
  - assay/devenv
```

`devenv.nix`:

```nix
{
  assay.checks.fmt = {
    exec = "cargo fmt --check";
    fast = true;
    requires = "Cargo.toml";
  };
  assay.checks.test = {
    exec = "cargo test";
    requires = "Cargo.toml";
  };
}
```

The module builds the CLI with the repo's own nixpkgs and puts it on the PATH, adds a pre-commit hook,
`devenv shell -- assay check --fast` (git runs hooks outside the devenv), and appends `assay check` to `enterTest`. So
`git commit` runs the fast checks over what is staged, and `devenv test` runs every pre-commit hook over all files,
then every check. `devenv.lock` pins assay; `devenv update assay` moves it.

### `assay.checks.<name>`

- `exec`: a shell command (bash) run from the repo root inside the devenv. A non-zero exit fails the check.
- `fast` (default `false`): the check only reads source files: no type checking, no build, no test run, no network.
  The whole fast set's budget is 5 s with a warm cache.
- `enable` (default `true`): whether `assay check` runs it.
- `requires` (default `null`): a glob relative to the repo root, in git's glob pathspec syntax (`**/` crosses
  directories). When no file git sees in the working tree matches it, the check is skipped and counts as passing: a
  new repo has no project yet.
- `coverage` (default `null`): the coverage report the check writes, LCOV or Cobertura (see below): a path, absolute
  or relative to the repo root, in which `$ASSAY_DIR` (or `${ASSAY_DIR}`) stands for `<git-dir>/assay`.
- `reason` (default `null`): why the repo loosens one of assay's default checks.

Names match `[A-Za-z0-9][A-Za-z0-9._-]*`.

assay's own default checks are set with `lib.mkDefault`, so a plain definition in the repo overrides one. Turning a
default off, redefining its `exec` or changing its `coverage` is a **loosening**: evaluation fails until the check has
a `reason`, and `assay check` lists every loosening with its reason in its header on every run.

### Coverage of new code

A check that declares `coverage` is measured on the change. `assay check` removes the report before the check runs;
when the check passes, it runs diff-cover on the report against the base (the base's tree against the working tree,
untracked files included), and the check fails unless `assay.coverage.newCode` percent (`80` unless set) of the new
lines the report can cover are covered. No exemption for small changes. A missing report, or a diff-cover that cannot
run, fails the check too. diff-cover comes from the module, which adds it to the devenv when an enabled check
declares `coverage`.

- Only the lines the report lists count: a file the report does not list counts neither as covered nor as
  uncovered. So each test check's report lists exactly its own language's sources, the ones no test loads included,
  and one language's report never counts another's new lines as uncovered.
- Lowering `assay.coverage.newCode` is a loosening: evaluation fails until `assay.coverage.reason` says why. Raising it
  is free.
- Whole-tree coverage is a metric, never a check.

### Default checks

Each language's checks are on when the repo enables the language in devenv (`languages.<language>.enable`), are named
after their tool, and bring their tools into the devenv. Each runs over the files git sees (tracked, or untracked and
not ignored), never over `.`, so `.devenv/` and other ignored files are never read; with nothing to check, it passes.

| Language | `--fast` | full run only |
| --- | --- | --- |
| Nix, `languages.nix.enable` | `nixfmt`, `statix`, `deadnix`, `nixf-tidy` | `nix-flake-check` (`nix flake check`), requires `flake.nix` |
| bash, `languages.shell.enable` | `shellcheck`, `shfmt` | `bats`, with `coverage` |

- Nix's checks run over the `.nix` files; `nixf-tidy` runs with `--variable-lookup` on each file, and any diagnostic
  fails it, whatever its severity. Nix has no coverage tool, so a Nix repo has no coverage check.
- bash's checks run over the shell files `shfmt -f` finds (by extension or shebang, `.bats` files included). shfmt
  keeps its defaults (tabs). `bats` runs the `.bats` files under kcov, whose Cobertura report,
  `$ASSAY_DIR/kcov/bats/cobertura.xml`, lists every shell script, those no test runs included, and nothing else.
- The commands call three helpers the module puts on the PATH (`devenv/bin`): `assay-files [<glob>...]` (the files
  git sees that exist, NUL-terminated), `assay-nixf-tidy <file>...` and `assay-bats <dir>`.

`assay.seed` (a positive 32-bit integer, `42` unless set) is exported as `ASSAY_SEED`, so that property-based tests run
with a fixed seed.

## `assay check`

```
assay check [--fast] [--base <rev>] [<check>...]    run the repo's checks
assay check --list                                  list them, fast ones marked
```

- Every selected check runs, one after another in name order, without stopping at the first failure. `--fast` selects
  the fast checks; names select those checks. A check runs over the whole working tree, never over the staged or
  changed files only.
- Output, on stdout: a header with the mode and the base, the loosenings and the skipped checks; one line per check
  (`ok`, `FAIL` or `skip`, its name, its seconds, and for a check with `coverage` how many new lines its report
  covers); for each failure its command, the first 100 lines of its output (of diff-cover's report, when it failed
  on coverage) and its full log, `<git-dir>/assay/<check>.log`; a last line with the count and the command that
  reruns the failures.
- Exit codes: `0` every selected check passed, `1` at least one failed, `2` assay could not run (usage, no
  configuration, no base, not in a git repo, a repo that has not adopted assay), with an `assay:` message on stderr.
- The base of the change, exported to each check as `ASSAY_BASE`: `--base`, else `ASSAY_BASE`, else GitHub's event
  when `GITHUB_EVENT_PATH` is set (`pull_request.base.sha`, or a push's `before` unless all zeros), else
  `git merge-base --fork-point <default> HEAD`, else `git merge-base <default> HEAD`. The default branch is
  `origin/HEAD`'s target, else `origin/main`, `origin/master`, `main` or `master`. assay never fetches: a base missing
  from the clone is exit 2.
- Each check also gets `ASSAY_DIR`, assay's directory in the git directory (`<git-dir>/assay`), where a check writes
  what must stay out of the tree, such as its coverage report.

### From outside the devenv

`assay` knows it runs inside the repo's devenv when `ASSAY_CONFIG` is set. Outside it, as in a shell that does not
activate direnv, `assay check <args>` re-executes itself as `devenv shell -- assay check <args>` from the repo root,
so the version the repo pins always decides; `nix run github:eff3ct0/assay -- check` behaves the same. A repo without
`devenv.nix`, or whose devenv does not import assay's module, is exit 2: the message names
[docs/adoption.md](docs/adoption.md) and says that an adoption is a change of its own, made before other work.

The machine-level subcommands, `guard`, `git-hook` and `collect`, never delegate; this version only prints their
usage.

## The hits log

When `ASSAY_HITS_LOG` names a file, each `assay check` run appends one JSON line to it, passing or not. Append-only
and best-effort: a failed write is ignored and never changes an exit code. The run that executes the checks writes
it, never the `assay` that delegates to the repo's devenv.

- Every line: `v` (the line format's version, `1`), `time` (UTC, RFC 3339), `source` (`guard`, `git-hook` or
  `check`), `repo` (the absolute path of the main checkout, from `git rev-parse --git-common-dir`), `agent` (the value
  of `ASSAY_AGENT`, or `null`).
- `check`: `mode` (`fast` or `full`), `only` (the check names given, as given; empty for all), `seconds`, `failed`
  (the failing checks' names) and `exit`.

```json
{"v":1,"time":"2026-11-18T21:04:05Z","source":"check","repo":"/path/to/repo","agent":null,"mode":"fast","only":[],"seconds":0.42,"failed":["lint"],"exit":1}
```

## License

[MIT](LICENSE)
