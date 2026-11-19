# Python's default checks, on with languages.python.enable (see ../defaults.nix for the shape), each skipped without
# pyproject.toml at the root. The standalone CLIs come from nixpkgs: ruff, pyright, vulture and osv-scanner. What loads
# the project's code runs from its venv, where the project's lockfile puts it and Python's preset adds it as a
# development dependency: pytest, coverage.py, Hypothesis and deptry, and import-linter while its check is on. Each
# runs from the repo root, and nothing to check is a pass.
{
  config,
  lib,
  pkgs,
}:
let
  helpers = pkgs.callPackage ../../nix/check-helpers.nix { };
  requirePythonProject = _: check: check // { requires = "pyproject.toml"; };
in
lib.optionalAttrs config.languages.python.enable (
  lib.mapAttrs requirePythonProject {
    # RUF100 reports a noqa that no longer silences anything; --no-fix keeps a repo's `fix = true` from editing the
    # tree.
    ruff-check = {
      exec = "ruff check --no-fix --extend-select RUF100";
      fast = true;
      packages = [ pkgs.ruff ];
    };
    ruff-format = {
      exec = "ruff format --check";
      fast = true;
      packages = [ pkgs.ruff ];
    };
    # vulture ignores .gitignore.
    vulture = {
      exec = "vulture . --exclude .venv,.devenv";
      fast = true;
      packages = [ pkgs.python3Packages.vulture ];
    };
    deptry = {
      exec = "assay-deptry";
      fast = true;
      packages = [ helpers ];
    };
    # Boundaries are the repo's to write, in import-linter's configuration: off until the repo turns it on, and then
    # `assay preset python` adds import-linter, which is not in nixpkgs and imports the project.
    import-linter = {
      exec = ''if command -v lint-imports >/dev/null; then lint-imports; else echo "lint-imports is not on the PATH: assay preset python adds import-linter to the project's development dependencies while this check is on"; exit 127; fi'';
      fast = true;
      enable = false;
    };
    # Strict through the preset's pyrightconfig.json, as pyright takes no flag for its mode or a rule; warnings fail.
    pyright = {
      exec = "pyright --warnings";
      packages = [ pkgs.pyright ];
    };
    pytest = {
      exec = ''assay-pytest "$ASSAY_DIR/pytest"'';
      coverage = "$ASSAY_DIR/pytest/coverage.xml";
      packages = [ helpers ];
    };
    # The advisories on the dependency versions the change adds or changes, never on the ones it leaves alone.
    osv-scanner = {
      exec = "assay builtin osv-scanner uv.lock";
      packages = [ pkgs.osv-scanner ];
    };
  }
)
