# Task: built-in checks every repo runs

Removed once the last critic passes.

## The request, verbatim

> /mattpocock-skills:implement https://github.com/eff3ct0/assay/issues/3
>
> Toma tú cada decisión con tu recomendación, sin esperarme. Sigue ~/git/AGENTS.md: worktree de grove en una rama
> agent/, y el crítico te toca a ti, porque tú eres el autor de este cambio. Termina con un pull request que diga
> "Closes https://github.com/eff3ct0/assay/issues/3" y no lo mergees.

Issue #3 ("Built-in checks every repo runs") is the specification; read it and the nixos-config issues it links.

## Decisions

- **CLI.** The built-in checks that are assay's own code run as `assay builtin <check>`: `agents-md [<commit>]`
  (the working tree, or a commit's tree), `commit-trailers [--base <rev>]`, `gitleaks`, `suppressions [--base <rev>]`.
  `assay new-code [--base <rev>]` prints the change's new code as JSON, `{"<path>": [[first, last], ...]}`. Both
  delegate into the repo's devenv like `assay check`; the base is resolved as `assay check` does (`ASSAY_BASE`, which
  `assay check` exports, comes second).
- **New code.** `git diff -U0 -M <base>` against the working tree with a temporary index that adds the untracked
  files as intent-to-add, so untracked files count; renames are followed; binary files and submodules add nothing.
- **agents-md.** One predicate (`agents_md_problems`) reads root entries from the working tree or a commit's tree
  with the same rules. Accepted shapes: `CLAUDE.md` exactly `@AGENTS.md` (one optional newline), `CLAUDE.md` a
  symlink to `AGENTS.md`, or `AGENTS.md` a symlink to `CLAUDE.md`; the file holding the instructions has an ATX
  heading "Related repos" (any level, case-insensitive). Any other symlink fails.
- **commit-trailers.** Any line of a commit message in `base..HEAD` matching `^\s*co-authored-by\s*:`,
  case-insensitively (`git log -i -E --grep`).
- **gitleaks.** `gitleaks dir` scans ignored files (`.devenv/`, a local `.env`), so `assay builtin gitleaks` scans a
  hard-linked copy (copy when hard links fail) of the files git sees, from its root, so paths, `.gitleaksignore`
  fingerprints and `.gitleaks.toml` work as from the repo root; secrets are redacted.
- **oxfmt.** The exec is the literal command of the issue, built in `devenv/defaults.nix` from
  `languages.javascript.{enable,directory}` (directory made relative to `devenv.root`).
- **suppressions.** Markers per language by extension (shell also by shebang). Markers with a reason field must use
  it (eslint/oxlint `--`, Rust `reason = "…"`, Stryker `:`, scalafix `;`, qlty's long form `qlty-ignore(…): …`,
  `@ts-expect-error TS<code>: …`); the others take a comment on the same line or a comment line just above.
  `@ts-ignore` and `@ts-nocheck` always fail. A suppression on new code whose marker and rules match one removed
  by the change (a modified or moved line) is not new and passes.
- **Workflow lint.** A sixth built-in fast check, `actionlint`, `requires = ".github/workflows/*"`; nixpkgs wraps it
  with shellcheck, which lints `run:` blocks. zizmor stays out (its default audits would rewrite every workflow, and
  its online audits need the network).
- **Tools** come from the defaults: each default check may list `packages`, which the module adds to every repo's
  devenv.
- **Tests.** `test/defaults/*.json` hold the configuration the module writes for three devenv setups; `nix flake
  check` compares the module's output with them, and the bats suite runs the built-in checks with them.
- **assay's own tree.** The hits log example in README.md becomes a `jsonl` block, which oxfmt leaves alone: a commit
  of its own.

## Remaining steps

1. Done: the jsonl commit, new code, the four builtins, the module defaults, the tests, the docs. `devenv test`,
   `nix flake check` and `nix develop -c bats test/devenv` pass.
2. code-review skill, critic, recheck critic, PR (`Closes https://github.com/eff3ct0/assay/issues/3`, not merged).
