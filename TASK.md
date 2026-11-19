# Task: Python's default checks and preset, and advisories on the change

Removed once the last critic passes.

## The request, verbatim

> https://github.com/eff3ct0/assay/issues/7
>
> Toma tú cada decisión con tu recomendación, sin esperarme. Sigue ~/git/AGENTS.md: worktree de grove en una rama
> agent/, y el crítico te toca a ti, porque tú eres el autor de este cambio. Termina con un pull request que diga
> "Closes https://github.com/eff3ct0/assay/issues/7" y no lo mergees.

A note sent while working, verbatim:

> Nota del orquestador, por un incidente de hoy (un crítico borró /run/user/1000): cuando lances un crítico o cualquier
> subagente que ejecute scripts, pon en su brief estos límites: scripts con set -euo pipefail; toda ruta que se borre o
> cambie de permisos usa ${VAR:?} y está dentro de un directorio creado con mktemp -d; nada de rm ni chmod -R sobre una
> ruta calculada sin comprobar antes que empieza por ese directorio. Tú también, y sigue con lo tuyo.

Issue #7 is the specification; it links eff3ct0/nixos-config#58, #50, #52, #54 and #57.

## Facts checked (flake nixpkgs: ruff 0.15.14, pyright 1.1.411, vulture 2.14, osv-scanner 2.3.3, uv 0.11.21; devenv-nixpkgs rolling: ruff 0.17.4, pyright 1.1.414, vulture 2.16, osv-scanner 2.7.0, uv 0.13.7)

- ruff: `ruff check --ignore <rule>` turns off one rule on top of the repo's configuration (issue's "To verify").
  `--extend-select RUF100` reports a stale `# noqa: F401`. No Python file: exit 0. Rules in PLR0904..PLR0917 that
  exist: 0904, 0911-0917, so the prefix `PLR09` is the issue's range. A file in `tests/` without `__init__.py` fails
  INP001; a root `conftest.py` does not.
- coverage.py: `include_namespace_packages` is a `[report]` option (in `[run]` coverage warns "Unrecognized option").
  With it, `--source=.` lists a `src/` layout's modules no test imports at 0%; `omit` keeps `.devenv/` out. With no
  Python file at all, `coverage xml` says "No data to report." and exits 1 writing nothing. diff-cover (10.2 and 10.6)
  takes an empty Cobertura report: 0 lines, exit 0.
- pyright: an unnecessary `# type: ignore` fails under the preset's config; no source file: exit 0.
- vulture: `--exclude .venv,.devenv` leaves `.devenv/` out; a public function nothing in the repo uses is reported
  (60% confidence, exit 3), a `src/` library's API included until a test uses it.
- deptry: the preset's root `conftest.py` imports hypothesis, a dev dependency: DEP004. deptry excludes `tests` by
  default but not `conftest.py`. CLI `--extend-exclude` replaces `[tool.deptry] extend_exclude` (not added to it), so
  the helper `assay-deptry` reads the repo's list and passes it with `(.*/)?conftest\.py`. deptry respects .gitignore.
- osv-scanner 2.x: `scan source --format json -L <path>`: exit 0 clean, 1 vulnerabilities, 128 no packages, 127 error;
  the parser is chosen by file name, so the base's copy keeps the lockfile's name.
- uv: `uv add --dev` writes `[dependency-groups] dev` (sorted); `uv add --dev pytest` keeps an existing `pytest>=8`.
  yq-go reads pyproject.toml (`-p toml`), inline tables in arrays included.
- devenv (modules at cachix/devenv 8efcb88): with `languages.python.uv.sync.enable` and no `pyproject.toml`, the task
  `devenv:python:uv` fails and `devenv:enterShell` is skipped ("dependency failed"); the command still runs (exit 0).
  The venv is on the PATH only with `languages.python.venv.enable`. Both go to p3rkins (the python template lives in
  nixos-config).

## Decisions

- Check names: `ruff-check`, `ruff-format`, `vulture`, `deptry`, `import-linter` (fast, off), `pyright`, `pytest`
  (coverage `$ASSAY_DIR/pytest/coverage.xml`), `osv-scanner`; all `requires = "pyproject.toml"`.
- Commands: `ruff check --no-fix --extend-select RUF100` (a repo's `fix = true` must not edit the tree);
  `ruff format --check`; `vulture . --exclude .venv,.devenv`; `assay-deptry`; `pyright --warnings` (warnings fail);
  `assay-pytest "$ASSAY_DIR/pytest"`; `assay builtin osv-scanner uv.lock`; import-linter's `lint-imports`, with a
  message naming `assay preset python` when it is not installed.
- `assay-pytest`: coverage run over pytest with `--hypothesis-profile=ci`, exit 5 a pass, Cobertura through
  `coverage xml`; "No data to report" (no Python file at all) writes an empty report, so diff-cover finds nothing.
- `assay builtin osv-scanner [--base <rev>] <lockfile>...`: one osv-scanner run over each lockfile in the working tree
  and its copy at the base; an advisory group is new when the base's lockfile has none of its ids for the same
  ecosystem, name and version. Untouched ones are never printed.
- `--list` marks off checks: "<name> (off)", "<name> (fast, off)" (the same lines as the #14 branch's wip).
- Python's preset 1: `ruff.toml` (`[lint]`, `PLR09` for PLR0904-PLR0917, per-file ignores for `**/test_*.py`,
  `**/*_test.py`, `**/tests/**`, `**/conftest.py`), `pyrightconfig.json`, `.coveragerc` (`[run] omit`,
  `[report] include_namespace_packages`), root `conftest.py` (`explore` profile, `max_examples` from `ASSAY_CASES`).
- Dependencies: `preset/<language>/<version>.dependencies`, one spec per line as the package manager takes it,
  optionally `when <check> is on`. Python's manager is uv (`uv add --dev`, `uv remove --dev`). A dependency the
  project lacks is added; one whose spec changed since the recorded version is upgraded; one a later version drops is
  removed; a conditional one is added only while its check is on, and never removed. The project's dev dependencies
  are read from pyproject.toml (`[dependency-groups] dev` and `[tool.uv] dev-dependencies`) with yq.
- The preset applies to python when `pyproject.toml` is a file git sees at the root.
- A tool configured in a section of another file: `[tool.ruff]`, `[tool.pyright]`, `[tool.coverage]` in
  pyproject.toml, `[coverage:*]` in setup.cfg or tox.ini: the preset writes no file of its own, shows the preset's
  file (or its change between versions) and exits 1. `.ruff.toml` is ruff's other file of the same format.

- vulture at its default confidence, as the issue gives the command: `uv init --lib`'s placeholder `hello()` fails it
  until a test uses it, so the acceptance's "devenv test passes" holds once that test exists (test/devenv/python.bats
  shows both). Open for p3rkins: `--min-confidence` would keep only what ruff already finds.
- deptry colours its output even into a file: `assay-deptry` passes `--no-ansi`.
- Hypothesis writes `.hypothesis/constants/` whatever the profile; the `ci` profile keeps no `.hypothesis/examples`.
- The devenv fixtures commit with `--no-verify` (commit_all): the consumer's pre-commit hook runs the fast checks, and a
  fixture's commit may hold what the test then shows failing; `devenv test` in the fresh-project test runs the hooks.

## Remaining steps

1. Done: preset, dependencies, `assay builtin osv-scanner`, `--list`, the module, helpers, fixtures (all 8 of
   test/devenv/python.bats pass; `bats test`: 266 ok), docs.
2. Running when the session stopped: `nix flake check` then `nix develop -c bats test/devenv` (logs were in the
   session's scratchpad); rerun both.
3. Fix the code review's findings (base cdd2d67):
   - Decide, do not defer: (a) vulture vs "devenv test passes" in a fresh `uv init --lib` project (recommendation:
     keep vulture's default confidence; the placeholder needs its test); (b) the venv on the PATH: the module sets
     neither `languages.python.venv.enable` nor `uv.sync.enable`, and uv sync fails without pyproject.toml.
     Recommendation: the module sets `venv.enable` with python, and `uv.enable`/`uv.sync.enable` with mkDefault only
     when pyproject.toml exists, if devenv's evaluation can see the file; else document it for the template.
   - Make the package-manager layer generic: manifest name and its hint ("uv init"), and project_dependencies, behind
     `case $manager`.
   - Stale docs: AGENTS.md Run (yq and uv for `assay preset`), nix/package.nix, nix/test-tools.nix and
     nix/check-helpers.nix comments, the comments above apply_preset and preset_lines; usage_text lists osv-scanner as
     a built-in check; use GLOSSARY's "untouched dependency"; lines over 120 in docs/adoption.md, AGENTS.md, README.md.
   - Duplication: one helper for apply_preset's two `git diff --no-index` blocks; a `path_without <tool>` test helper
     for the four PATH-filtering loops; osv-scanner's own --base parsing vs parse_base_option; python_devenv pasted
     twice in test/devenv/python.bats.
   - Names: `python` in devenv/languages/python.nix (it adds `requires`), `lines()` in test/stub/osv-scanner.
   - The "nothing written" comment in cmd_preset holds only for planning: a failing `uv add` after bash's files leaves
     them; reword or order the dependency runs before any language's files.
   - Keep, with the reason in the PR: `--no-fix` (a repo's `fix = true` would edit the tree), `--warnings` (#58: warnings
     fail), `PLR09` (= #52's "PLR09xx"), setup.cfg/tox.ini sections (coverage.py reads them before pyproject.toml),
     dependencies the project lacks added back (as a missing file is written again).
4. Critic per ~/git/CLAUDE.md (brief with the safety limits quoted above), then its recheck; PR with
   "Closes https://github.com/eff3ct0/assay/issues/7", not merged; remove this file once the last critic passes.
