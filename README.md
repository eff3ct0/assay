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

The module builds the CLI with the repo's own nixpkgs and puts it on the PATH, adds the
[built-in checks](#built-in-checks) with their tools, adds a pre-commit hook, `devenv shell -- assay check --fast`
(git runs hooks outside the devenv), and appends `assay check` to `enterTest`. So `git commit` runs the fast checks
over what is staged, and `devenv test` runs every pre-commit hook over all files, then every check. `devenv.lock` pins
assay; `devenv update assay` moves it.

### `assay.checks.<name>`

- `exec`: a shell command (bash) run from the repo root inside the devenv. A non-zero exit fails the check.
- `fast` (default `false`): the check only reads source files: no type checking, no build, no test run, no network.
  The whole fast set's budget is 5 s with a warm cache.
- `enable` (default `true`): whether `assay check` runs it.
- `requires` (default `null`): a glob relative to the repo root, in git's glob pathspec syntax (`**/` crosses
  directories). When no file git sees in the working tree matches it, the check is skipped and counts as passing: a
  new repo has no project yet.
- `reason` (default `null`): why the repo loosens one of assay's default checks.

Names match `[A-Za-z0-9][A-Za-z0-9._-]*`.

assay's own default checks are set with `lib.mkDefault`, so a plain definition in the repo overrides one. Turning a
default off or redefining its `exec` is a **loosening**: evaluation fails until the check has a `reason`, and
`assay check` lists every loosening with its reason in its header on every run.

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
  (`ok`, `FAIL` or `skip`, its name, its seconds); for each failure its command, the first 100 lines of its output
  and its full log, `<git-dir>/assay/<check>.log`; a last line with the count and the command that reruns the
  failures.
- Exit codes: `0` every selected check passed, `1` at least one failed, `2` assay could not run (usage, no
  configuration, no base, not in a git repo, a repo that has not adopted assay), with an `assay:` message on stderr.
- The base of the change, exported to each check as `ASSAY_BASE`: `--base`, else `ASSAY_BASE`, else GitHub's event
  when `GITHUB_EVENT_PATH` is set (`pull_request.base.sha`, or a push's `before` unless all zeros), else
  `git merge-base --fork-point <default> HEAD`, else `git merge-base <default> HEAD`. The default branch is
  `origin/HEAD`'s target, else `origin/main`, `origin/master`, `main` or `master`. assay never fetches: a base missing
  from the clone is exit 2.

### From outside the devenv

`assay` knows it runs inside the repo's devenv when `ASSAY_CONFIG` is set. Outside it, as in a shell that does not
activate direnv, `assay check <args>` re-executes itself as `devenv shell -- assay check <args>` from the repo root,
so the version the repo pins always decides; `nix run github:eff3ct0/assay -- check` behaves the same. A repo without
`devenv.nix`, or whose devenv does not import assay's module, is exit 2: the message names
[docs/adoption.md](docs/adoption.md) and says that an adoption is a change of its own, made before other work.

The machine-level subcommands, `guard`, `git-hook` and `collect`, never delegate; this version only prints their
usage.

## Built-in checks

Every repo that imports the module runs these, whatever its languages, and all of them are fast. The tools they run
(actionlint, gitleaks and oxfmt, from the repo's nixpkgs) join the repo's devenv, so the fix commands run there too.
They are default checks: turning one off or redefining its `exec` is a loosening.

- `actionlint`: the GitHub workflows, skipped without `.github/workflows/*`: their syntax, their expressions, and
  shellcheck over each `run:` block. zizmor is not run: its default audits would rewrite every workflow, and its
  online audits need the network.
- `agents-md`: `AGENTS.md` and `CLAUDE.md` exist at the root; `CLAUDE.md` is the single line `@AGENTS.md`, or either
  file is a symlink to the other (`AGENTS.md` or `./AGENTS.md`, and the same for `CLAUDE.md`); a copy fails, even an
  identical one. The file that holds the instructions has a "Related repos" heading, of any level; whether what it
  says is right stays prose. `assay builtin agents-md <commit>` reads a commit's tree instead of the working tree,
  with the same answers.
- `commit-trailers`: no commit in `base..HEAD` has a line that starts with `Co-Authored-By:`, in any case. In CI it
  catches what slipped past local hooks (`--no-verify`, commits made on GitHub).
- `gitleaks`: gitleaks over the files git sees in the working tree, tracked or untracked but not ignored (a local
  `.env` or `.devenv/` is not read); history is not scanned. A secret is fixed by removing it, and rotating it if it
  ever left the machine. A false positive's fingerprint, printed with each finding, goes in `.gitleaksignore`; the
  repo's `.gitleaks.toml` applies as usual.
- `oxfmt`: oxfmt's defaults over Markdown and YAML in every repo, plus a JavaScript project's own files when
  `languages.javascript.enable` is set, under `languages.javascript.directory`. The command, run from the root:

  ```sh
  oxfmt --check --no-error-on-unmatched-pattern '**/*.{md,mdx,yml,yaml}' \
    '<dir>/**/*.{js,jsx,mjs,cjs,ts,tsx,mts,cts,json,jsonc,json5,css,scss,less,html,vue}'
  ```

  The second pattern only for JavaScript, with no `<dir>/` at the root. TOML is never checked (cargo and uv write
  it), JSON only in a JavaScript project, and nothing to check is a pass. The fix is the same command without
  `--check`, which `assay check` prints with the failure; a bare `oxfmt` would format more. A tool-written file of a
  checked type (a sops file, say) goes in the repo's `.oxfmtrc.json` under `ignorePatterns`, which is no loosening.

- `suppressions`: a suppression (a comment or attribute that silences a finding at its place) added on new code
  names the rule it silences and gives a reason. Old suppressions never block a change: one on a line the change
  leaves alone is not read, and one the change also removes from the same file, with the same marker and rules (a
  modified or moved line, in a file git sees as the same or renamed), is not new.

The markers `suppressions` knows, by language (by a file's extension, and by its shebang for a shell script without
one), each in a form that passes:

| Language                                         | Marker                                             | Passes as                                                        |
| ------------------------------------------------ | -------------------------------------------------- | ---------------------------------------------------------------- |
| JavaScript, TypeScript (`js` `ts` `vue` and kin) | `eslint-disable`, `-line`, `-next-line`            | `// eslint-disable-next-line no-console -- <why>`                |
|                                                  | `oxlint-disable`, `-line`, `-next-line`            | `// oxlint-disable-next-line no-console -- <why>`                |
|                                                  | `@ts-expect-error`                                 | `// @ts-expect-error TS2345: <why>`                              |
|                                                  | `@ts-ignore`, `@ts-nocheck`                        | never                                                            |
|                                                  | `Stryker disable`                                  | `// Stryker disable next-line EqualityOperator: <why>`           |
| Python (`py` `pyi`)                              | `noqa`, `ruff: noqa`, `flake8: noqa`               | `# noqa: E501  # <why>`                                          |
|                                                  | `type: ignore`                                     | `# type: ignore[attr-defined]  # <why>`                          |
|                                                  | `pyright: ignore`                                  | `# pyright: ignore[reportAttributeAccessIssue]  # <why>`         |
|                                                  | `pragma: no cover`, `pragma: no branch`            | `# pragma: no cover  # <why>`                                    |
| Rust (`rs`)                                      | `#[allow]`, `#[expect]`, `#![allow]`, `#![expect]` | `#[allow(clippy::too_many_lines, reason = "<why>")]`             |
|                                                  | `#[mutants::skip]`                                 | `#[mutants::skip] // <why>`                                      |
| Scala (`scala` `sc` `sbt`)                       | `@nowarn`                                          | `@nowarn("cat=deprecation") // <why>`                            |
|                                                  | `@SuppressWarnings`                                | `@SuppressWarnings(Array("org.wartremover.warts.Var")) // <why>` |
|                                                  | `scalafix:off`, `scalafix:ok`                      | `// scalafix:ok DisableSyntax.var; <why>`                        |
| shell (`sh` `bash` `bats`)                       | `shellcheck disable`                               | `# shellcheck disable=SC2086 # <why>`                            |
| all but shell                                    | `qlty-ignore`                                      | `// qlty-ignore(eslint:camelcase): <why>`                        |

- A marker with a reason field gives the reason there: ESLint's and oxlint's `--`, Rust's `reason = "…"`, Stryker's
  `:`, scalafix's `;`, `qlty-ignore`'s long form, `@ts-expect-error`'s description. One without (`noqa`,
  `type: ignore`, `pyright: ignore`, `pragma`, `shellcheck disable`, `@nowarn`, `@SuppressWarnings`,
  `#[mutants::skip]`) takes a comment on the same line or a comment line just above.
- Naming the rule: a blanket form fails (`# noqa`, `# type: ignore`, `/* eslint-disable */`, `shellcheck disable=all`,
  `Stryker disable all`, `qlty-ignore: eslint`). `@ts-expect-error` names the TypeScript error's code, and `pragma`
  and `#[mutants::skip]` have no rule to name.
- `ast-grep-ignore` is not this check's: the `ast-grep` check bans it outright.

### New code

**New code** is the lines a change adds or modifies, compared with its base: the base's tree against the working
tree, untracked files included (ignored ones not), following renames. Binary files and submodules add none.
`suppressions` reads it, and so will the `findings` check. `assay new-code` prints it:

```sh
$ assay new-code
{"src/app.py":[[3,5],[12,12]],"src/new.py":[[1,40]]}
```

### `assay builtin` and `assay new-code`

```
assay builtin agents-md [<commit>]                  the AGENTS.md / CLAUDE.md shape, of the working tree or a commit
assay builtin commit-trailers [--base <rev>]        no Co-Authored-By in base..HEAD
assay builtin gitleaks                              secrets in the files git sees
assay builtin suppressions [--base <rev>]           new suppressions name their rule and give a reason
assay new-code [--base <rev>]                       the change's new code, as JSON
```

The built-in checks that are assay's own code run as `assay builtin <check>`, which is their `exec`; an agent can run
one alone. The base is `assay check`'s, from `ASSAY_BASE` when `assay check` runs them. Exit codes: `0` passed, `1`
failed, `2` could not run, `127` the check's tool (gitleaks) is missing. Outside the repo's devenv they re-execute themselves through it, as `assay check` does.

## The hits log

When `ASSAY_HITS_LOG` names a file, each `assay check` run appends one JSON line to it, passing or not. Append-only
and best-effort: a failed write is ignored and never changes an exit code. The run that executes the checks writes
it, never the `assay` that delegates to the repo's devenv.

- Every line: `v` (the line format's version, `1`), `time` (UTC, RFC 3339), `source` (`guard`, `git-hook` or
  `check`), `repo` (the absolute path of the main checkout, from `git rev-parse --git-common-dir`), `agent` (the value
  of `ASSAY_AGENT`, or `null`).
- `check`: `mode` (`fast` or `full`), `only` (the check names given, as given; empty for all), `seconds`, `failed`
  (the failing checks' names) and `exit`.

```jsonl
{"v":1,"time":"2026-11-18T21:04:05Z","source":"check","repo":"/path/to/repo","agent":null,"mode":"fast","only":[],"seconds":0.42,"failed":["lint"],"exit":1}
```

## License

[MIT](LICENSE)
