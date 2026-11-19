# shellcheck disable=SC2016 # the fixtures' Python and Nix text is literal
bats_require_minimum_version 1.5.0
# shellcheck source=test/devenv/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# Python's default checks and preset through the real devenv, uv, PyPI and the OSV API: a fixture project built with
# `uv init --lib` and `assay preset python`, each check failing on a defect and passing on its fix, the test check's
# coverage of new code and fixed seed, and the advisory check on the change. The consumers import a copy of assay with
# the languages' default checks alone, so that the built-in ones stay out of the way, except where `devenv test` runs
# them all.

# The devenv.nix of a Python project: the venv first on the PATH, and uv syncing it from the lockfile, as the python
# template sets them.
python_devenv='{
  languages.python = {
    enable = true;
    venv.enable = true;
    uv = {
      enable = true;
      sync.enable = true;
    };
  };
}'

# check_fails <check> <text>: `assay check <check>` fails, and its output holds the text.
check_fails() {
	run --separate-stderr devenv shell -- assay check "$1"
	echo "$output"
	[ "$status" -eq 1 ]
	[[ ${lines[1]} == "FAIL $1 "* ]]
	[[ $output == *"$2"* ]]
}

# check_passes <check>...: `assay check <check>...` passes.
check_passes() {
	run --separate-stderr devenv shell -- assay check "$@"
	echo "$output"
	[ "$status" -eq 0 ]
}

# python_project [assay source]: a consumer whose devenv sets up Python with uv, the project `uv init --lib` writes,
# and Python's preset taken by `assay preset python`, whose output is checked; not committed.
python_project() {
	consumer "${1:-$ASSAY_LANGUAGES}"
	devenv_nix "$python_devenv"
	printf '%s\n' .venv/ __pycache__/ .pytest_cache/ .ruff_cache/ .hypothesis/ >>.gitignore
	devenv shell -- uv init --quiet --lib --name demo . >/dev/null 2>&1
	[ -f pyproject.toml ]
	run --separate-stderr devenv shell -- assay preset python
	echo "$output"
	[ "$status" -eq 0 ]
	output_is 'wrote .coveragerc' 'wrote conftest.py' 'wrote pyrightconfig.json' 'wrote ruff.toml' \
		'added dependency pytest' 'added dependency coverage' 'added dependency hypothesis' 'added dependency deptry' \
		'wrote .assay-preset.json'
	local f
	for f in .coveragerc conftest.py pyrightconfig.json ruff.toml; do diff "$ASSAY/preset/python/1/$f" "$f"; done
	holds .assay-preset.json '{' '  "python": 1' '}'
	local dependency
	for dependency in pytest coverage hypothesis deptry; do
		grep -q "^    \"$dependency>=" pyproject.toml
		grep -q "^name = \"$dependency\"$" uv.lock
	done
}

# commit_all <message>: commit every change without the pre-commit hook, which runs the fast checks: a fixture's
# commit may hold what a check fails on, which the test then shows.
commit_all() {
	git add -A
	git commit --quiet --no-verify -m "$1"
}

# hello_test: the test the function `uv init --lib` writes needs, with tests/ a package (ruff's INP001).
hello_test() {
	mkdir -p tests
	: >tests/__init__.py
	printf '%s\n' 'from demo import hello' '' '' 'def test_hello() -> None:' '    assert hello() == "Hello from demo!"' \
		>tests/test_hello.py
}

@test "Python: --list shows four fast checks, import-linter off and three full; without pyproject.toml all are skipped" {
	consumer "$ASSAY_LANGUAGES"
	devenv_nix '{ languages.python.enable = true; }'
	run --separate-stderr devenv shell -- assay check --list
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' 'deptry (fast)' 'import-linter (fast, off)' osv-scanner pyright pytest \
		'ruff-check (fast)' 'ruff-format (fast)' 'vulture (fast)')" ]
	run --separate-stderr devenv shell -- assay check
	echo "$output"
	[ "$status" -eq 0 ]
	local n
	for n in deptry osv-scanner pyright pytest ruff-check ruff-format vulture; do
		[[ $output == *$'\n'"  skipped: $n (no pyproject.toml)"$'\n'* ]]
	done
	[ "${lines[-1]%% in *}" = "7 checks passed (7 skipped)" ]
}

@test "Python: in a fresh uv init --lib project, assay preset python takes the preset, and devenv test passes" {
	python_project "$ASSAY"
	shape
	# uv's own placeholder, a public function nothing uses, is dead code to vulture until a test uses it.
	check_fails vulture "src/demo/__init__.py:1: unused function 'hello' (60% confidence)"
	hello_test
	# The pre-commit hook runs the fast checks, the built-in ones included.
	git add -A
	git commit --quiet -m project
	run devenv test
	echo "$output"
	[ "$status" -eq 0 ]
	# Every check ran, each with a log.
	local logs n
	logs=$(git rev-parse --absolute-git-dir)/assay
	for n in deptry osv-scanner pyright pytest ruff-check ruff-format vulture preset findings; do [ -f "$logs/$n.log" ]; done
	[ ! -e "$logs/import-linter.log" ]
}

@test "Python: ruff, ruff format, vulture, deptry and pyright fail on their defects and pass on the fix" {
	python_project
	hello_test
	commit_all project
	# .venv/ and the devenv's venv hold dead code of their own, which vulture never reads.
	mkdir -p .venv/lib
	printf '%s\n' 'def venv_only():' '    pass' >.venv/lib/dead.py
	[ -d .devenv/state/venv/lib ]
	check_passes

	printf '%s\n' 'import os  # noqa: F401' '' '' 'def separator() -> str:' '    return os.sep' >src/demo/util.py
	check_fails ruff-check "RUF100"
	printf '%s\n' 'import os' '' '' 'def separator() -> str:' '    return os.sep' >src/demo/util.py
	check_passes ruff-check

	printf '%s\n' 'X=1' >src/demo/style.py
	check_fails ruff-format "src/demo/style.py"
	printf '%s\n' 'X = 1' >src/demo/style.py
	check_passes ruff-format

	check_fails vulture "src/demo/util.py:4: unused function 'separator' (60% confidence)"
	printf '%s\n' 'from demo.util import separator' '' '' 'def test_separator() -> None:' \
		'    assert separator() == "/"' >tests/test_util.py
	run --separate-stderr devenv shell -- assay check vulture
	echo "$output"
	[[ $output != *$'\n.venv/'* && $output != *$'\n.devenv/'* ]]
	[[ $output == *"src/demo/style.py:1: unused variable 'X' (60% confidence)"* ]]
	rm src/demo/style.py
	check_passes vulture

	printf '%s\n' 'import requests' '' '' 'def get() -> object:' '    return requests' >src/demo/net.py
	check_fails deptry "src/demo/net.py:1:8: DEP001 'requests' imported but missing from the dependency definitions"
	rm src/demo/net.py
	# The preset's conftest.py imports hypothesis, a development dependency, which deptry allows there.
	check_passes deptry

	printf '%s\n' 'VALUE: int = 1  # type: ignore[assignment]' >src/demo/typed.py
	check_fails pyright 'Unnecessary "# type: ignore" comment'
	printf '%s\n' 'VALUE: int = 1' >src/demo/typed.py
	check_passes pyright
}

@test "Python: pytest fails with a test; a module no test imports is in the report at 0% and fails the new code" {
	python_project
	hello_test
	commit_all project
	printf '%s\n' 'def test_fails() -> None:' '    assert 1 == 2' >tests/test_fails.py
	check_fails pytest "1 failed"
	rm tests/test_fails.py

	printf '%s\n' 'def lonely(x: int) -> int:' '    return x + 1' >src/demo/lonely.py
	check_fails pytest "(new code: 0 of 2 lines covered, 0%, under 80%)"
	local report
	report=$(git rev-parse --absolute-git-dir)/assay/pytest/coverage.xml
	grep -A4 'filename="src/demo/lonely.py"' "$report" >"$T/lonely"
	grep -q 'line-rate="0"' "$T/lonely"
	grep -q '<line number="2" hits="0"/>' "$T/lonely"

	printf '%s\n' 'from demo.lonely import lonely' '' '' 'def test_lonely() -> None:' '    assert lonely(1) == 2' \
		>tests/test_lonely.py
	run --separate-stderr devenv shell -- assay check pytest
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[1]} == "ok   pytest "*"(new code: 5 of 5 lines covered)" ]]
}

@test "Python: sources with no test pass pytest's exit 5, their new lines uncovered; no source and no test pass" {
	python_project
	commit_all project
	printf '%s\n' 'def more() -> int:' '    return 1' >>src/demo/__init__.py
	check_fails pytest "(new code: 0 of 2 lines covered, 0%, under 80%)"
	local log
	log=$(git rev-parse --absolute-git-dir)/assay/pytest.log
	grep -q '^assay-pytest: pytest collected no test (exit 5), which passes$' "$log"
	git rm --quiet -r -f src conftest.py
	run --separate-stderr devenv shell -- assay check pytest
	echo "$output"
	[ "$status" -eq 0 ]
	[[ ${lines[1]} == "ok   pytest "*"(new code: no lines to cover)" ]]
}

@test "Python: Hypothesis runs with the ci profile, so two runs of the test check try the same inputs" {
	python_project
	hello_test
	printf '%s\n' 'import os' 'from pathlib import Path' '' 'from hypothesis import given' \
		'from hypothesis import strategies as st' '' '' '@given(st.integers())' 'def test_seen(n: int) -> None:' \
		'    with Path(os.environ["SEEN"]).open("a") as f:' '        f.write(f"{n}\n")' >tests/test_seen.py
	commit_all project
	SEEN=$T/first devenv shell -- assay check pytest >/dev/null
	SEEN=$T/second devenv shell -- assay check pytest >/dev/null
	[ -s "$T/first" ]
	cmp "$T/first" "$T/second"
	[ ! -e .hypothesis/examples ]
}

@test "Python: a change that locks a version with an advisory fails osv-scanner; the same version at the base passes" {
	python_project
	commit_all project
	check_passes osv-scanner
	devenv shell -- uv add --quiet 'urllib3==2.2.1' >/dev/null 2>&1
	check_fails osv-scanner "uv.lock: urllib3 2.2.1 (PyPI): "
	[[ $output == *"on dependency versions this change adds or changes"* ]]
	commit_all urllib3
	check_passes osv-scanner
}

@test "Python: import-linter, once on, is added by assay preset python, and fails on a broken contract" {
	python_project
	commit_all project
	devenv_nix '{
  languages.python = {
    enable = true;
    venv.enable = true;
    uv = {
      enable = true;
      sync.enable = true;
    };
  };
  assay.checks.import-linter.enable = true;
}'
	check_fails import-linter "assay preset python adds import-linter"
	run --separate-stderr devenv shell -- assay preset python
	echo "$output"
	[ "$status" -eq 0 ]
	output_is 'added dependency import-linter'
	printf '%s\n' '[importlinter]' 'root_package = demo' '' '[importlinter:contract:core]' \
		'name = core does not import cli' 'type = forbidden' 'source_modules =' '    demo.core' \
		'forbidden_modules =' '    demo.cli' >.importlinter
	printf '%s\n' 'def main() -> None:' '    pass' >src/demo/cli.py
	printf '%s\n' 'from demo.cli import main' '' '' 'def run() -> None:' '    main()' >src/demo/core.py
	check_fails import-linter "1 broken"
	printf '%s\n' 'def run() -> None:' '    pass' >src/demo/core.py
	check_passes import-linter
}
