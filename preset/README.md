# Presets

A language's **preset** is the configuration files and development dependencies its default checks need in a repo.
assay holds every version of each language's preset here; `assay preset` writes the pinned one into a repo, which owns
the files from then on, and merges later versions in ([README.md](../README.md#assay-preset)).

## Layout

- `preset/<language>/<version>/` holds every file of that version, at the path it takes in the repo, from the repo
  root. The language is assay's name for it, the one `.assay-preset.json` records (`bash`, enabled in devenv with
  `languages.shell.enable`).
- `preset/<language>/<version>.dependencies`, beside it, holds the version's development dependencies, when it has
  any: one per line, as the language's package manager adds it (`pytest`, `pytest>=9`), optionally followed by
  `when <check> is on` for one only that check needs; a line starting with `#` is a comment. `assay preset` adds them
  with the project's package manager (`preset_manager` in `assay.sh`: uv for Python), never by editing a manifest
  itself.
- The highest version is the pinned one: what a repo gets from the version of assay its `devenv.lock` pins.
- Every version stays, so that a repo at any of them merges the pinned one in three ways, with its recorded version
  as the base, without network.
- Nix has no preset: its tools need no configuration.

## What a preset holds

A preset holds what the tool checks (which rules, how strict, licenses, boundaries), while a default check's command
holds what makes the tool a check and assay's policy.

How strict: everything a tool offers that finds defects, and nothing that only enforces a style choice the formatter
or another check already makes. Where a language's strictness can only live in its project file, the preset keeps the
tool's defaults.

## When a preset applies, and where it writes

- `assay preset` with no language takes every language the repo's devenv enables whose preset applies; the `preset`
  check fails while such a language is missing from the record.
- bash's applies once the repo tracks a shell script, as `shfmt -f` finds them (by extension or shebang). Its files
  go at the repo root, since shellcheck reads `.shellcheckrc` from each script's directory upward.
- Python's applies once `pyproject.toml` is at the root. Its files go at the root, where the tools run from.
- A tool may read its configuration from elsewhere than the preset's file: another file first (shellcheck reads
  `shellcheckrc` where a directory has no `.shellcheckrc`; ruff reads `.ruff.toml` before `ruff.toml`), or a section of a
  file of another format (`[tool.ruff]`, `[tool.pyright]` or `[tool.coverage]` in `pyproject.toml`, `[coverage:*]` in
  `setup.cfg` or `tox.ini`). When the repo has one, it is the tool's: the preset writes no file of its own beside it,
  which would silently replace it. Another file of the same format is merged into and shown as the preset's own would
  be; a section, which neither can take, is shown the preset's file, or its change between two versions, to fold in by
  hand. `preset_reads` in `assay.sh` lists them, in each tool's order.

## Raising a version

1. Copy `preset/<language>/<N>/` to `<N + 1>/`, and `<N>.dependencies` to `<N + 1>.dependencies` when there is one,
   and make the change there. Never edit a version that has shipped: repos recorded at it merge from it.
2. A file the new version drops stays in the repos that have it, which own it.
3. The fixtures of `test/devenv/defaults.bats` and `test/devenv/python.bats` are built from the pinned version by
   `assay preset`, so assay's own tests prove what repos receive; adjust them with the change.
4. A dependency the new version drops is removed from the projects that have it; one whose spec it changes is
   upgraded. For uv, direct version clauses are intersected and the project's extras kept. Where the change cannot
   safely update the existing requirement (such as marker variants), resolve it in `pyproject.toml` and rerun.
5. Repos take it with `assay preset`, which the weekly update runs. Until then, `assay check`'s header lists the
   language as behind; a version behind fails nothing.

## bash

Version 1:

- `.shellcheckrc`: `enable=check-extra-masked-returns,check-set-e-suppressed,check-unassigned-uppercase`, the
  optional checks that find defects rather than set style.
- No `.editorconfig`: shfmt keeps its defaults (tabs).

## Python

Version 1:

- `ruff.toml`: `select = ["ALL"]` under `[lint]`, every rule ruff has; `ignore`: `D` (docstrings), `C90` and `PLR09`
  (pylint's PLR0904 to PLR0917: complexity's one source is qlty's smells), `COM812`, `ISC001` and `E501` (what the
  formatter decides), `CPY` and `TD`. In tests (`test_*.py`, `*_test.py`, `tests/`, `conftest.py`), `S101` and
  `PLR2004` are allowed. A `tests/` directory needs an `__init__.py`: ruff's `INP001` fails a file of an implicit
  namespace package.
- `pyrightconfig.json`: `typeCheckingMode: "strict"`, and `reportUnnecessaryTypeIgnoreComment: "error"`, which strict
  leaves off and no flag sets.
- `.coveragerc`: `[run] omit` of `.venv/*` and `.devenv/*`, and `[report] include_namespace_packages = true`, without
  which a `src/` layout (`uv init --lib`) leaves the files no test loads out of the report. (It is a `[report]`
  option: under `[run]`, coverage.py warns that it does not know it.)
- `conftest.py`, at the root: registers Hypothesis's `explore` profile, for many more cases than a run of
  `assay check` tries, `ASSAY_CASES` of them when it is set: `ASSAY_CASES=10000 pytest --hypothesis-profile=explore`.
  The test check passes `--hypothesis-profile=ci`, Hypothesis's own.
- Development dependencies (`1.dependencies`), through `uv add --dev` into `[dependency-groups] dev`: `pytest`,
  `coverage`, `hypothesis`, `deptry`; and `import-linter` while the `import-linter` check is on.
