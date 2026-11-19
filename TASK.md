# Task: Nix and bash default checks, and coverage of new code

Removed once the last critic passes.

## The request, verbatim

> /mattpocock-skills:implement https://github.com/eff3ct0/assay/issues/4

Issue #4 ("Nix and bash default checks, and coverage of new code") is the specification; read it and the
nixos-config issues it links (#50, #52, #58, #56, #47). Branch `agent/nix-bash-defaults`, worktree
`~/git/eff3ct0/assay.wt/agent-nix-bash-defaults`, base `8ee15d5`.

## Decisions

- **`coverage`** (`assay.checks.<name>.coverage`, config `checks.<name>.coverage`): null or a path, relative to the
  repo root unless absolute; `$ASSAY_DIR` or `${ASSAY_DIR}` in it stands for `<git-dir>/assay`, which `assay check`
  exports to every check as `ASSAY_DIR`. assay removes the report before the check runs, so a stale one never counts.
- **After a passing check with `coverage`**, assay runs, with the caller's PATH, `diff-cover <report>
  --compare-branch=<base sha> --diff-range-notation=.. --include-untracked --format json:<tmp>`. Pass when
  `covered * 100 >= newCode * total` (exact, no rounding), or when nothing is measured. Otherwise the check fails:
  `FAIL <name> <s> (new code: <c> of <t> lines covered, <p>%, under <n>%)`, and its failure section shows the
  `diff-cover` command and its console report. diff-cover's output is appended to the check's log. A missing report
  or a diff-cover that cannot run also fails the check. A passing check's line adds `(new code: c of t lines
  covered)` or `(new code: no lines to cover)`.
- **Limited to its own sources (to verify, verified):** diff-cover counts only the lines its report measures; a file
  absent from the report counts neither as covered nor as uncovered (`XmlCoverageReporter._cache_file`: no class →
  no violations, no measured lines). So each test check's report must list exactly its own language's sources:
  bash's kcov runs with `--include-path` set to the shell files git sees (`shfmt -f`), `.bats` files excluded.
- **Files no test loads (to verify, verified):** kcov's `--bash-parse-files-in-dir` walks directories and parses
  every file whose start looks like shell, executed or not; `--include-path` then keeps the shell files git sees. The
  walk covers the top-level directories holding shell files (the root when a script sits there).
- **kcov 43 with bats 1.14 loses coverage** after every `run` (bats traces `saved_traps=$'…\'…'`, which leaves
  kcov's quote tracking in a single-quote state). Fixed upstream in SimonKagstrom/kcov#501, after v43; nixpkgs has 43.
  `nix/kcov.nix` applies that patch (`nix/kcov-ansi-c-quote.patch`); module and flake share it.
- **Config:** `coverage: {newCode: <0-100>}`, required once a check declares `coverage`; loosenings gain kinds `coverage` (a default check's `coverage`
  changed: dropped or another report; needs that check's `reason`) and `new-code` (`assay.coverage.newCode` below
  assay's default, `{kind, newCode, default, reason}`, reason from `assay.coverage.reason`). Version stays 1: module
  and CLI always ship together.
- **Tools:** a default check may list `packages` (the mechanism agent/builtin-checks chose for issue #3, same name);
  the module adds them to the devenv. diff-cover joins the devenv when an enabled check declares `coverage`.
- **Helpers** (`devenv/bin/`, packaged by the module, on the devenv's PATH):
  - `assay-files [<glob>...]`: the files git sees (tracked or untracked, not ignored) that exist, matching the globs
    (git glob pathspecs from the root), NUL-terminated;
  - `assay-nixf-tidy <file>...`: nixf-tidy `--variable-lookup` per file, each diagnostic as `file:line:col: severity
    sname: message`, exit 1 on any;
  - `assay-bats <dir>`: bats over the tracked `.bats` files under kcov into `<dir>` (removed first); kcov runs a
    runner in bats' place that first names every script to kcov at line 0, so the report lists every script, those
    kcov's walk misses included; with no `.bats` file the runner reports no test; kcov's stderr (trace noise) goes to
    `<dir>/kcov.stderr`.
- **Default checks** (named after their tool):
  - Nix, `languages.nix.enable`: `nixfmt`, `statix`, `deadnix`, `nixf-tidy` fast, each over `assay-files '*.nix'`;
    `nix-flake-check` (`nix flake check`, `requires = "flake.nix"`).
  - bash, `languages.shell.enable`: `shellcheck`, `shfmt` fast, over `assay-files | xargs -0 -r shfmt -f | tr '\n'
    '\0' | xargs -0 -r <tool>`; `bats` full, `assay-bats "$ASSAY_DIR/kcov"`, `coverage =
    "$ASSAY_DIR/kcov/bats/cobertura.xml"`.
  - bats runs the tracked `.bats` files, as the issue says (the critic's finding; untracked ones ran before).
  - kcov only where nixpkgs has it (Linux), in the module and in `nix/test-tools.nix`, so darwin still evaluates.
  - `coverage.newCode` is required in the config only when a check declares `coverage`: a configuration of the base's
    shape still runs.
- **Tests:** `test/coverage.bats` (CLI, real diff-cover), `test/defaults.bats` (the helpers against fixture repos,
  real tools), `test/devenv/defaults.bats` (each default check failing on a defect and passing on its fix through
  the real devenv; coverage end to end; `newCode = 50` with and without reason), `nix/checks.nix` (module).
- **assay itself:** `devenv.nix` enables `languages.nix` and `languages.shell`, drops its `bats` check; each check's
  cleanup of the tree is its own commit (shfmt's reformat to tabs, shellcheck over the `.bats` files, ...).

## Remaining steps

Done: steps 1-6 and the code review (its fixes in `fix: review findings…`: assay-bats names every script to kcov at
line 0, since kcov's walk misses a `.bash` library without "sh" in its first 80 bytes).

1. Critic, then one recheck critic on its failures.

Open decisions for p3rkins (not to be decided by an agent):

- `.git-blame-ignore-revs` for the shfmt commit (`style: shfmt's reformat…`) only makes sense if the branch is not
  squash-merged.
- kcov is nixpkgs' kcov patched (`nix/kcov.nix`), so it builds from source where no cache has it.
- `ASSAY_DIR` and the `coverage` loosening kind are interface the issue did not name.
- With a script at the repo root, kcov's `--bash-parse-files-in-dir` walks the whole root, ignored trees included.
