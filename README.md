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
- `coverage` (default `null`): the coverage report the check writes, LCOV or Cobertura (see below): a path, absolute
  or relative to the repo root, in which `$ASSAY_DIR` (or `${ASSAY_DIR}`) stands for `<git-dir>/assay`.
- `reason` (default `null`): why the repo loosens one of assay's default checks.

Names match `[A-Za-z0-9][A-Za-z0-9._-]*`.

assay's own default checks are set with `lib.mkDefault`, so a plain definition in the repo overrides one. Turning a
default off, redefining its `exec` or changing its `coverage` is a **loosening**: evaluation fails until the check has
a `reason`, and `assay check` lists every loosening with its reason in its header on every run.

`assay.seed` (a positive 32-bit integer, `42` unless set) is exported as `ASSAY_SEED`, so that property-based tests run
with a fixed seed.

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

The machine-level subcommands, [`guard` and `git-hook`](#on-a-machine-the-guard-and-the-global-git-hooks) and
`collect`, never delegate; this version only prints `collect`'s usage.

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
`(not on new code)` (a linter's) or `(at the base too)` (a smell's):

```
$ assay findings
src/app.py:23: radarlint-python/python:S1481: Remove the unused local variable "w".
src/app.py:1: qlty/function-complexity: Function with high complexity (count = 28): tangled (at the base too)
src/app.py:7: qlty/nested-control-flow: Deeply nested control flow (level = 5) (at the base too)

3 findings on the change, 1 of them new: the findings check fails on those
```

`--sarif` prints one SARIF 2.1.0 log with two runs, the lint findings and the smells, each result's `baselineState`
`new` or `unchanged`. Exit codes: `0` whenever it ran, with findings or without, since consulting the analyzer stops
nobody; `2` when it could not run (qlty missing or failing included).

A **new finding** is one the change introduces, and the `findings` check fails on each new one, whatever its level:

- A linter's finding (radarlint's) is about a place: it is new when any of its lines is new code.
- A smell is about a piece of code (a function, a file, a nested block, an expression, a clone): it is new when the
  base has no counterpart, the same rule in the same file (following renames) and, for one about a function, the same
  function; a clone's place, when the base has no clone's place in the same file between the same files. So a smell
  that existed at the base and grew does not fail. A nested block or a boolean expression, which has no function to
  tell it from another of its file, is also new when the line it starts on is new code, an edited one included.

qlty refuses to run without `.qlty/qlty.toml`, which holds store paths: assay writes `.qlty/` on every run, from
`assay.findings`, and keeps it out of git with a `.qlty/` line in `.git/info/exclude`. A repo that tracks
`.qlty/qlty.toml` is exit 2. qlty runs with `QLTY_TELEMETRY=off` (its package sets it on every run), and its plugins
run the tools of the repo's devenv: qlty downloads nothing. qlty is packaged for `x86_64-linux` only; elsewhere the
`findings` check exits 127.

### `assay.findings`

qlty's defaults hold: function complexity 18, file complexity 50, nested control flow 5, function parameters 6,
return statements 6, boolean logic 4, identical and similar code 15 lines, duplication's `nodes_threshold` 64, for
every language (it replaces qlty's own 50 for Rust: values are per repo, not per language). A repo changes them in its
`devenv.nix`:

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

## Each language's checks

Each language's checks are on when the repo enables the language in devenv (`languages.<language>.enable`), are named
after their tool, and bring their tools into the devenv. They are default checks: turning one off, redefining its
`exec` or changing its `coverage` is a loosening. Each runs over the files git sees (tracked, or untracked and
not ignored), though `bats` runs only the tracked `.bats` files as tests; none runs over `.`, so `.devenv/` and other
ignored files are never read; with nothing to check, it passes.

| Language                       | `--fast`                                   | full run only                                               |
| ------------------------------ | ------------------------------------------ | ----------------------------------------------------------- |
| Nix, `languages.nix.enable`    | `nixfmt`, `statix`, `deadnix`, `nixf-tidy` | `nix-flake-check` (`nix flake check`), requires `flake.nix` |
| bash, `languages.shell.enable` | `shellcheck`, `shfmt`                      | `bats`, with `coverage`                                     |

- Nix's checks run over the `.nix` files; `nixf-tidy` runs with `--variable-lookup` on each file, and any diagnostic
  fails it, whatever its severity. Nix has no coverage tool, so a Nix repo has no coverage check.
- bash's checks run over the shell files `shfmt -f` finds (by extension or shebang, `.bats` files included). shfmt
  keeps its defaults (tabs). `bats` runs the tracked `.bats` files under kcov, whose Cobertura report,
  `$ASSAY_DIR/kcov/bats/cobertura.xml`, lists every shell script, those no test runs included, and nothing else.
  nixpkgs has kcov for Linux only: elsewhere `bats` fails on the missing tool until the repo turns it off with a
  reason.
- The commands call three helpers the module puts on the PATH (`devenv/bin`): `assay-files [<glob>...]` (the files
  git sees that exist, NUL-terminated), `assay-nixf-tidy <file>...` and `assay-bats <dir>`.

## On a machine: the guard and the global git hooks

The machine-level half of assay: the **agent guard**, `assay guard`, which reads one harness hook event and allows,
denies, or keeps a turn going; and the **global git hooks**, `assay git-hook`, which check commits and pushes in every
repo on the machine and leave no trace in any of them. Both read one **rule list**, which a machine keeps in its own
home-manager configuration: assay ships the engine and no rules. The guard is a guardrail against habits, not a
security boundary: matching command text can be evaded (`bash -c`, variables), and that is accepted.

### The home-manager module

```nix
{
  inputs.assay.url = "github:eff3ct0/assay";
  # In a home-manager configuration:
  imports = [ inputs.assay.homeManagerModules.default ];
  programs.git.enable = true;
  programs.assay = {
    enable = true;
    rules = [
      {
        name = "no-clone";
        on = "command";
        match = {
          kind = "command";
          all = [
            { has = { field = "name"; regex = "^git$"; }; }
            { has = { kind = "word"; regex = "^(clone|worktree)$"; }; }
          ];
        };
        message = "Get repos and worktrees through the workspace tool, not git clone or git worktree.";
        note = "Why: …\nFix: …\nNot a fix: …";
        deny = [ "cd x && git clone y" "git -C r worktree add ../x" ];
        allow = [ "git commit -m \"explain git clone\"" ];
      }
    ];
  };
}
```

- `programs.assay.enable` puts `assay` (`programs.assay.package`) on the user's PATH.
- `programs.assay.rules`: the rule list, one Nix list; several definitions merge. It is rendered into one JSON file,
  `programs.assay.rulesFile` (read-only), which both entrypoints read with `--rules`. Its types validate it when the
  configuration evaluates: a rule without a one-line message or without a `deny` and an `allow` example, a `match` or
  an example its `on` cannot take, or two rules with one name fail evaluation. A broken list never reaches the
  machine.
- The global git hooks, as config-based hooks in home-manager's git configuration (`programs.git.settings`; git 2.54
  or later), which run in every repo beside the repo's own hooks and need no `core.hooksPath`:
  `hook.assay-commit-msg.event = commit-msg` with
  `hook.assay-commit-msg.command = <package>/bin/assay git-hook --rules <rulesFile> commit-msg`, and the same for
  `pre-push`. With `programs.git.enable` off they are not written, and evaluation warns.
- `ASSAY_HITS_LOG` set to `$XDG_STATE_HOME/assay/hits.jsonl` in the user's environment (`home.sessionVariables`), so
  only this machine records [hits](#the-hits-log).
- The harness's hooks call `assay guard --rules <rulesFile>`: Claude Code's `PreToolUse` (Bash, Edit, Write,
  NotebookEdit) and `Stop` hooks, or an OpenCode plugin that builds the same JSON. Wiring them, and setting the agent
  marker `ASSAY_AGENT` to the harness's name in the agent's environment, is the machine's configuration.

### Rules

| Field         | What it holds                                                                                         |
| ------------- | ----------------------------------------------------------------------------------------------------- |
| `name`        | The rule's stable id, which the hits log records. `[A-Za-z0-9][A-Za-z0-9._-]*`, unique.               |
| `on`          | `command`, `path`, `commit-msg`, `pre-push` or `stop`: what the rule judges, and which entrypoint.    |
| `match`       | What breaks the rule, by `on` (below).                                                                |
| `message`     | One line: what is wrong and what to do instead.                                                       |
| `note`        | Why, Fix, Not a fix, and the closing line (default empty).                                            |
| `who`         | `agents` (the default): the rule runs only when `ASSAY_AGENT` is non-empty. `everyone`: always.       |
| `cwd`         | A `command` rule only: a glob or `main-checkout`; the rule runs only when the event's cwd matches it. |
| `fileContent` | A `command` rule only: a regex over the file the match binds to `$FILE` (below).                      |
| `deny`        | Examples the rule must deny, at least one: the corrected command, path, message, push or state.       |
| `allow`       | Examples the rule must let through, at least one: its fix, plus a near miss.                          |

By `on`:

- `command`, by `assay guard` on the Bash tool's command: `match` is an ast-grep rule for bash, the value of a rule
  file's `rule:`, or, with a `rule` key, a rule file's body (`rule`, `constraints`, `utils`, `transform`). Every
  command rule runs at once, through `ast-grep scan --inline-rules <rules> --stdin`. It matches
  the command's structure, not its text: `cd x && git clone y`, `git -C r worktree add ../x`, `git -c x=y clone z`,
  `FOO=1 git clone z`, and a command inside `$(…)`, a pipeline, a subshell or an `if` match a `has` rule on the name
  `git` and the word `clone`; `git commit -m "explain git clone"` and `echo git clone` do not. A command handed as a
  string or as arguments to another program is not caught, and that is accepted: `bash -c "git clone x"`,
  `sudo git clone x`, `env git clone x`, `xargs git clone`.
  - With `cwd`, the rule runs only when the session's cwd matches it: `cwd = "main-checkout"` denies `git commit` in a
    main checkout and lets it through in a linked worktree.
  - With `fileContent`, a match that binds the metavariable `$FILE` counts only when the file it names holds text
    matching the regex: `{ has = { pattern = "$FILE"; follows.regex = "^(--body-file|-F)$"; }; }` reads the body of
    `gh pr create --body-file body.md`. The file is read relative to the cwd, with the quotes around it, a leading
    `--option=` and a leading `~/` resolved as the shell would; a file that cannot be read (`-`, a variable) holds
    nothing. A match that binds no `$FILE` counts as usual, so one rule covers `--body` and `--body-file` with `any`.
- `path`, by `assay guard` on the path an Edit, Write or NotebookEdit writes (relative to the cwd when it is not
  absolute): `match` is a glob or `main-checkout`, a path inside a main checkout: in its working tree, whose git dir
  is its common dir (a linked worktree's is not), or in the git dir of a repo that is not bare. A path that does not
  exist yet is judged by its nearest existing directory. In a glob, `*` and `?` stay
  within a path component and `**` crosses them, `[…]` is a class (`[!…]` negated) and `\` makes the next character
  plain. A glob with no `/` matches the file's name (`*.env`), one that starts with `/` the whole path (`/etc/**`),
  any other the path's end at a component boundary (`.ssh/*`).
- `commit-msg`, by `assay git-hook … commit-msg`: `match` is a regex in jq's syntax (Oniguruma, Perl-like) over the
  message as git stores it, with what follows `git commit --verbose`'s scissors line cut off and comments stripped.
  `^` and `$` match at the message's ends unless `(?m)` makes them match at each line; `(?i)` ignores case:
  `(?im)^co-authored-by:`.
- `pre-push`, by `assay git-hook … pre-push`: `match` names a check built into assay.
  - `agent-branch`: every pushed `refs/heads/*`, a deletion included, is `agent/*` or the remote's default branch
    (`refs/remotes/<remote>/HEAD`, else what `git ls-remote --symref` says; an empty remote takes any first branch).
    Tags and other refs pass.
  - `agents-md`: every pushed branch tip's tree has the `AGENTS.md` / `CLAUDE.md` shape of the
    [`agents-md`](#built-in-checks) check, read from the tree, in every repo.
- `stop`, by `assay guard` on a `Stop` event: `match` is `unsaved-work`, a session whose cwd is in a worktree with
  uncommitted changes (untracked files included) or, when the repo has a remote, commits on no remote-tracking branch.

Examples are strings or attribute sets. A string stands for a `command`'s command, a `path`'s path, a
`commit-msg`'s message or a `pre-push`'s pushed ref; an attribute set says more:

| `on`         | Fields                                                                                          |
| ------------ | ----------------------------------------------------------------------------------------------- |
| `command`    | `command`; `cwd` (default the fixture's root); `files`, written under the cwd before it runs    |
| `path`       | `path`; `cwd`                                                                                   |
| `commit-msg` | `message`                                                                                       |
| `pre-push`   | `ref` (default `refs/heads/agent/example`); `files`, the tip's files over a tree with the shape |
| `stop`       | `uncommitted`, `unpushed`, `remote` (default `true`): the session's worktree; no string form    |

In `files`, `null` removes a file.

### `assay guard --rules <file>`

- One hook event on stdin, in Claude Code's hook JSON (`hook_event_name`, `tool_name`, `tool_input`, `cwd`,
  `stop_hook_active`). Claude Code's documented format is the canonical one: another harness's adapter builds the
  same JSON and reads the same answers.
- `PreToolUse`: Bash runs the `command` rules; Edit, Write and NotebookEdit run the `path` rules over `file_path` or
  `notebook_path`. Other tools and events pass.
- Allow: no output, exit 0. Deny: exit 0 and
  `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "<reason>"}}`.
- `Stop`: when a `stop` rule finds unsaved work, the guard keeps the turn going once with
  `{"decision": "block", "reason": "<reason>"}`; with `stop_hook_active` set, a Stop hook already did, and it answers
  nothing.
- The reason holds every violated rule: its message, a detail line (the path, or the worktree and what is unsaved),
  and its note after a blank line.
- It fails open: on its own error (a rules file it cannot read or use, an event that is not JSON, no ast-grep), exit 1
  with an `assay:` message on stderr, which Claude Code shows without blocking. Never exit 2, which would block. It
  sits in front of every tool call, including the ones that would repair it.

### `assay git-hook --rules <file> <hook> [<git's arguments>]`

- Git appends the hook's own arguments and gives it stdin: the message file for `commit-msg`; the remote's name and
  URL, plus `<local ref> <local oid> <remote ref> <remote oid>` lines on stdin, for `pre-push`.
- A hook with no rules exits 0. A violated rule makes it exit 1, with `assay: <name>: <message>`, its details and its
  note on stderr, for every violated rule.
- It fails closed: when it cannot evaluate its rules (a rules file it cannot read or use, a regex jq rejects, a hook
  other than `commit-msg` and `pre-push`, a remote whose default branch it cannot find), exit 1 with
  `assay: cannot evaluate rules: …`. It stands only in front of commits and pushes, and a person can still bypass it.

### Testing a rule list

assay's flake exports a check builder, `lib.rulesCheck`:

```nix
checks.${system}.agent-rules = inputs.assay.lib.rulesCheck {
  inherit pkgs;
  rules = self.homeConfigurations.<name>.config.programs.assay.rulesFile;
};
```

`assay` (by default the package the module installs by default) is the package whose entrypoints it runs: a
configuration that sets `programs.assay.package` passes the same one, since command rules depend on its ast-grep. It
builds `assay-rules-check`, which feeds every example to the real entrypoint its rule's `on` names, with that rule
alone and `ASSAY_AGENT` set or not as `who` asks: a `PreToolUse` or `Stop` event to `assay guard`, a message file or
a pushed ref to `assay git-hook`. It fails when a `deny` example passes, an `allow` example is denied, or an
entrypoint fails on one, naming the rule and the example; its output is the report. It takes seconds and needs no
KVM, so a configuration's CI can build it. Each example runs in a fresh fixture, under a root that is its default cwd
and is in no repository:

- `origin.git`: a bare remote whose default branch is `main`;
- `repo/`: its clone, a main checkout on `main`, pushed, whose files have the `AGENTS.md` / `CLAUDE.md` shape;
- `worktree/`: a linked worktree of `repo` on `agent/example`, pushed, its upstream set; `pre-push` examples push
  from it, and `stop` examples run in it;
- `local/`: a repo with one commit and no remote, where a `stop` example with `remote = false` runs.

So a `main-checkout` path rule takes `repo/README.md` as a `deny` example and `worktree/README.md` as an `allow` one.

## The hits log

When `ASSAY_HITS_LOG` names a file, each `assay check` run appends one JSON line to it, passing or not, and so does
each denial and block of `assay guard` and each rejection of `assay git-hook`, one line per rule. Allowed calls,
accepted commits and accepted pushes write nothing. Append-only and best-effort: a failed write is ignored and never
changes an exit code or an answer. The run that executes the checks writes it, never the `assay` that delegates to the
repo's devenv.

- Every line: `v` (the line format's version, `1`), `time` (UTC, RFC 3339), `source` (`guard`, `git-hook` or
  `check`), `repo` (the absolute path of the main checkout, from `git rev-parse --git-common-dir`), `agent` (the value
  of `ASSAY_AGENT`, or `null`).
- `check`: `mode` (`fast` or `full`), `only` (the check names given, as given; empty for all), `seconds`, `failed`
  (the failing checks' names) and `exit`.
- `guard`: `event` (`PreToolUse` or `Stop`), `tool` (the tool's name; `null` for `Stop`), `rule` (its name) and
  `decision` (`deny` or `block`). `repo` is the event's cwd's.
- `git-hook`: `hook` (`commit-msg` or `pre-push`) and `rule`.

```jsonl
{"v":1,"time":"2026-11-18T21:04:05Z","source":"check","repo":"/path/to/repo","agent":null,"mode":"fast","only":[],"seconds":0.42,"failed":["lint"],"exit":1}
{"v":1,"time":"2026-11-18T21:05:10Z","source":"guard","repo":"/path/to/repo","agent":"claude-code","event":"PreToolUse","tool":"Bash","rule":"no-clone","decision":"deny"}
{"v":1,"time":"2026-11-18T21:06:00Z","source":"git-hook","repo":"/path/to/repo","agent":"claude-code","hook":"pre-push","rule":"agent-branch"}
```

## License

[MIT](LICENSE)
