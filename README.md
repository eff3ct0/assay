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

Every repo that imports the module runs these, whatever its languages, and all of them but `findings` are fast. The
tools they run (actionlint, gitleaks and oxfmt from the repo's nixpkgs; qlty, and radarlint for Python and Scala, from
assay's own packages) join the repo's devenv, so the fix commands run there too. They are default checks: turning one
off or redefining its `exec` is a loosening.

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
- `findings`, in the full run only: no new finding among those [`assay findings`](#assay-findings) shows.
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
`suppressions` and the `findings` check read it. `assay new-code` prints it:

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
assay builtin findings [--base <rev>]               no new finding on the change
assay new-code [--base <rev>]                       the change's new code, as JSON
```

The built-in checks that are assay's own code run as `assay builtin <check>`, which is their `exec`; an agent can run
one alone. The base is `assay check`'s, from `ASSAY_BASE` when `assay check` runs them. Exit codes: `0` passed, `1`
failed, `2` could not run, `127` the check's tool (gitleaks, qlty, radarlint) is missing. Outside the repo's devenv
they re-execute themselves through it, as `assay check` does.

## `assay findings`

```
assay findings [--base <rev>] [--sarif]             the analyzer's findings on the change
```

The **analyzer** an agent consults about its own change while it works: the qlty CLI, run in the repo itself, with no
server. It runs `qlty check --upstream <base>` (lint findings, on changed lines only) and
`qlty smells --upstream <base>` (every smell of a changed file). The base is `assay check`'s. Outside the repo's
devenv it re-executes itself through it, as `assay check` does.

qlty runs only what no other check runs, so that a finding fails one check only:

- radarlint's plugins (SonarSource's analyzers) for Python and Scala, in a repo that sets `languages.python.enable` or
  `languages.scala.enable`, with Sonar's cognitive complexity (`S3776`) off: complexity has one source, the smells;
- smells, for TypeScript, Rust, Python and Scala: function and file complexity, nested control flow, parameters,
  return statements, boolean logic, and identical or similar code, a clone naming each of its places. Nix and bash
  have none: qlty's smells do not parse them.
- Not qlty's shellcheck, shfmt, ESLint, clippy, ruff or Nix plugins: those tools are checks of their own.

Output, on stdout: the findings by file, the lint findings first, then the smells, each as
`<path>:<line>: <tool>/<rule>: <message>`, and a count. A finding that does not fail the `findings` check ends in
`(not on new code)` or `(at the base too)`:

```
$ assay findings
src/app.py:23: radarlint-python/python:S1481: Remove the unused local variable "w".
src/app.py:1: qlty/function-complexity: Function with high complexity (count = 28): tangled (at the base too)
src/app.py:7: qlty/nested-control-flow: Deeply nested control flow (level = 5) (not on new code)

3 findings on the change, 1 of them new: the findings check fails on those
```

`--sarif` prints one SARIF 2.1.0 log with two runs, the lint findings and the smells, each result's `baselineState`
`new` or `unchanged`. Exit codes: `0` whenever it ran, with findings or without, since consulting the analyzer stops
nobody; `2` when it could not run (qlty missing or failing included).

A **new finding** is one the change introduces, and the `findings` check fails on each new one, whatever its level:

- A finding about a line (radarlint's, nested control flow, boolean logic) is new when its line, the one printed, is
  new code.
- A finding about a function or a file (function and file complexity, parameters, return statements) is new when the
  base has no counterpart: the same rule, file (following renames) and function. So a smell that existed at the base
  and grew does not fail.
- A clone's place is new when the base has no clone's place in the same file between the same files.

qlty refuses to run without `.qlty/qlty.toml`, which holds store paths: assay writes `.qlty/` on every run, from
`assay.findings`, and keeps it out of git with a `.qlty/` line in `.git/info/exclude`. A repo that tracks
`.qlty/qlty.toml` is exit 2. qlty runs with `QLTY_TELEMETRY=off` (its package sets it on every run), and its plugins
run the tools of the repo's devenv: qlty downloads nothing. qlty is packaged for `x86_64-linux` only; elsewhere the
`findings` check exits 127.

### `assay.findings`

qlty's defaults hold: function complexity 18, file complexity 50, nested control flow 5, function parameters 6,
return statements 6, boolean logic 4, identical and similar code 15 lines, duplication's `nodes_threshold` 64 (Rust's
own, 50, stays). A repo changes them in its `devenv.nix`:

```nix
{
  assay.findings.smells.function_complexity = {
    threshold = 25;
    reason = "the parser in src/grammar.py is one big match; see #12";
  };
  assay.findings.rules."python:S1192" = {
    enable = false;
    reason = "string constants repeat in the generated schema";
  };
}
```

- `smells.<kind>`, one of `boolean_logic`, `file_complexity`, `function_complexity`, `function_parameters`,
  `identical_code`, `nested_control_flow`, `return_statements`, `similar_code`: `enable` (default `true`) and
  `threshold`. `smells.duplication.nodes_threshold`.
- `rules.<key>.enable`: a radarlint rule, by Sonar's key; `python:S3776` and `scala:S3776` are off by default. There is
  no warning tier: a rule nobody wants is turned off, not downgraded.
- Raising a threshold, turning a smell off or turning a rule off is a loosening: evaluation fails until its `reason`
  is set, and `assay check` lists it in its header
  (`loosening: findings smells.function_complexity.threshold is 25, above qlty's 18: <reason>`). Lowering a threshold
  or turning a rule on is free.

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
