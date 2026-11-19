# Adopting assay

An **adopted repo** is one whose default branch's devenv imports assay's module. In a repo that has not adopted
assay, `assay check` exits 2 and names this page: the repo has no `devenv.nix`, or its devenv does not import the
module.

## An adoption is its own change

- One change per repo, on its own branch and pull request, made before any unrelated work, and it lands green: every
  check passes, in CI too, when it merges.
- An agent that meets a repo that has not adopted assay tells the user, and does not fold the adoption into the task
  at hand. The adoption goes first unless the user says otherwise (an urgent fix, say).

## What it changes

### devenv

- The repo gains `devenv.yaml` and `devenv.nix`, or extends the ones it has, with the `assay` input and its import,
  plus the `git-hooks` input until devenv 2.4.1 (which brings it from assay's own `devenv/devenv.yaml`), as
  [README.md](../README.md#in-a-repo) shows.
- It enables its languages in `devenv.nix` (`languages.<language>.enable = true;`).
- `.gitignore` gains devenv's entries (`.devenv*`, `devenv.local.nix`, `devenv.local.yaml`) and
  `.pre-commit-config.yaml`, which devenv's git-hooks writes at the root as a symlink into the store. `devenv.lock`
  is committed: it pins assay.
- No check is left skipped for a language the repo enables, unless the repo really has no such project: a project in
  a subdirectory gets its checks' `requires` pointed there.

### One source of tool versions

devenv is the one source of tool versions, reading the language's own pin where devenv supports one
(`rust-toolchain.toml`, `packageManager` through corepack). What duplicates it goes: `mise.toml`, and the toolchain
setup actions in CI. Two sources drift, and then CI and the agent check with different tools.

### Tool configuration

The repo's own tool configuration stays the source; assay injects none at run time. The adoption runs `assay preset`,
which writes the presets' files the repo lacks, keeps the ones it has and shows each against the preset (exit 1 when
they differ), and records the versions it took in `.assay-preset.json`, which is committed. The adoption then extends
each kept file by hand to hold what the preset holds, keeping the repo's own settings; what the tree cannot meet yet is
debt, held as below. The built-in `preset` check fails while an enabled language whose preset applies is missing from
the record.

### CI

- Every CI step that passes or fails on the tree becomes a named check (`assay.checks.<name>`), so the agent and the
  critic run what CI runs.
- CI becomes one job running `devenv test`, with no matrix: assay's own
  [`.github/workflows/check.yml`](../.github/workflows/check.yml), on pull requests and on pushes to the default
  branch. It sets no `ASSAY_BASE`: assay reads the base from GitHub's event itself, and `fetch-depth: 0` puts it in
  the clone.
- Workflows that are not checks stay: release, deploy, docs, bots.
- Where the repo's owner keeps a security configuration for dependencies (alerts and grouped security updates), the
  adoption attaches it to the repo: from then on, `devenv test` in CI verifies those updates' pull requests.

### Checks that need more than the tree

- A service devenv can start (a database for integration tests, say) makes an ordinary check.
- A check CI cannot run stays out of `assay check`, as a loosening with its reason.

### Existing debt

Whole-tree checks fail on day one wherever the tree already breaks them.

- Each check's cleanup goes in its own commit.
- A formatter's whole-tree reformat goes in its own commit, listed in `.git-blame-ignore-revs`.
- The built-in checks hold from the adoption on, whatever the repo's languages: the shape of `AGENTS.md` and
  `CLAUDE.md` (below), no secret in the tree, and `oxfmt` over Markdown and YAML, whose first run is such a reformat. A
  tool-written file of a type `oxfmt` checks (a sops file, say) goes in the repo's `.oxfmtrc.json` under
  `ignorePatterns`, which is no loosening.
- What cannot be cleaned is held as a loosening whose reason names an issue in that repo; `assay check` lists it on
  every run, and that issue removes the loosening when it clears the debt.

### AGENTS.md

"Related repos" names `eff3ct0/assay` (its devenv module, through the devenv input `assay`), and the run and test
instructions name `assay check`: `devenv test` runs every check, as CI does, and while working
`devenv shell -- assay check [--fast] [<check>...]` (or plain `assay check`, which runs itself inside the devenv).
`CLAUDE.md` is the single line `@AGENTS.md` (or either file a symlink to the other), as the built-in `agents-md`
check asks.

## Keeping assay current

- A repo with a remote gains the weekly update workflow: every Monday, and on demand, it runs `devenv update assay`
  and `assay preset`, which brings later preset versions; when anything changed it runs `devenv test`, and only when
  that passes does it land the change as a `devenv.lock: update` commit, pushed to the default branch, or as one pull
  request, refreshed by each run, where the default branch requires a review. A failed run lands nothing and leaves
  the pin where it was. Only `assay` moves; the repo's other inputs are its own business.
- A repo with no remote updates by hand: `devenv update assay`.
- `devenv update assay` in an ordinary change brings a fix sooner.

## A defect in assay

A defect in assay found during an adoption is fixed in assay and picked up with `devenv update assay`, never worked
around in the repo. If the adoption cannot wait, a loosening whose reason names assay's issue holds the place.
