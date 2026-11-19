bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# Python's preset through `assay preset`: its files, the development dependencies it adds with uv (the stub in
# test/stub/uv, which logs its calls to UV_STUB_CALLS and edits pyproject.toml's dev group), and the sections of
# pyproject.toml, setup.cfg and tox.ini that hold a tool's configuration in place of a preset file. Later versions are
# synthetic (python_version_2).

preset_dir=$BATS_TEST_DIRNAME/../preset/python/1

# python_repo: a repo whose devenv enables Python, with the pyproject.toml `uv init --lib` writes, committed, as the
# current directory.
python_repo() {
	local_repo
	languages python
	printf '%s\n' '[project]' 'name = "demo"' 'version = "0.1.0"' 'requires-python = ">=3.13"' 'dependencies = []' \
		>pyproject.toml
	git add pyproject.toml
	git commit --quiet -m project
	export UV_STUB_CALLS=$T/uv.calls
	: >"$UV_STUB_CALLS"
}

# python_version_2 [<dependency line>...]: a copy of assay's presets with a synthetic version 2 of Python's, whose files
# are version 1's and whose dependencies are the lines given, made the presets assay reads (assay_presets).
python_version_2() {
	assay_presets=$(mktemp -d "${T:?}/presets.XXXXXX")
	cp -r "$BATS_TEST_DIRNAME/../preset/." "$assay_presets"
	cp -r "$assay_presets/python/1" "$assay_presets/python/2"
	printf '%s\n' "$@" >"$assay_presets/python/2.dependencies"
	export assay_presets
}

dev_group() { awk '/^dev = \[$/ { on = 1; next } on && /^\]$/ { on = 0 } on' pyproject.toml; }

@test "python's preset applies once pyproject.toml is at the root, tracked or not, and not ignored" {
	local_repo
	languages python
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 0 ]
	echo '[project]' >pyproject.toml
	run --separate-stderr "$assay" builtin preset
	echo "$output"
	[ "$status" -eq 1 ]
	output_is "python's preset applies (the repo has pyproject.toml), and .assay-preset.json does not list python" \
		'run: assay preset python'
	echo pyproject.toml >.gitignore
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 0 ]
	rm .gitignore
	mkdir sub
	mv pyproject.toml sub/
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 0 ]
}

@test "assay preset writes python's four files, adds its dependencies with one uv add --dev, and records version 1" {
	python_repo
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 0 ]
	output_is 'wrote .coveragerc' 'wrote conftest.py' 'wrote pyrightconfig.json' 'wrote ruff.toml' \
		'added dependency pytest' 'added dependency coverage' 'added dependency hypothesis' 'added dependency deptry' \
		'wrote .assay-preset.json'
	holds "$UV_STUB_CALLS" 'add --dev pytest coverage hypothesis deptry'
	local f
	for f in .coveragerc conftest.py pyrightconfig.json ruff.toml; do diff "$preset_dir/$f" "$f"; done
	holds .assay-preset.json '{' '  "python": 1' '}'
	run --separate-stderr "$assay" builtin preset
	[ "$status" -eq 0 ]
	# Run again, it has nothing to do, and calls no uv.
	: >"$UV_STUB_CALLS"
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is "python's preset 1: up to date"
	[ ! -s "$UV_STUB_CALLS" ]
}

@test "a dependency the project already has, in either of uv's dev lists and under any spelling, is not added" {
	python_repo
	printf '%s\n' '' '[dependency-groups]' 'dev = [' '    "PyTest>=8",' '    { include-group = "lint" },' ']' \
		'lint = ["ruff"]' '' '[tool.uv]' 'dev-dependencies = ["Coverage[toml] >= 7", "hypo_thesis"]' >>pyproject.toml
	run --separate-stderr "$assay" preset python
	echo "$output"
	[ "$status" -eq 0 ]
	[[ $output == *$'\nadded dependency hypothesis\nadded dependency deptry\n'* ]]
	[[ $output != *"dependency pytest"* && $output != *"dependency coverage"* ]]
	holds "$UV_STUB_CALLS" 'add --dev hypothesis deptry'
}

@test "import-linter is added only while its check is on, and never removed" {
	python_repo
	check import-linter lint-imports --fast --off
	"$assay" preset >/dev/null
	holds "$UV_STUB_CALLS" 'add --dev pytest coverage hypothesis deptry'
	check import-linter lint-imports --fast
	: >"$UV_STUB_CALLS"
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 0 ]
	output_is 'added dependency import-linter'
	holds "$UV_STUB_CALLS" 'add --dev import-linter'
	dev_group >"$T/dev"
	grep -qx '    "import-linter",' "$T/dev"
	check import-linter lint-imports --fast --off
	: >"$UV_STUB_CALLS"
	run --separate-stderr "$assay" preset
	output_is "python's preset 1: up to date"
	[ ! -s "$UV_STUB_CALLS" ]
}

@test "a later version upgrades a dependency whose spec changed, adds a new one and removes a dropped one" {
	python_repo
	"$assay" preset >/dev/null
	python_version_2 'pytest>=9' coverage hypothesis mutmut 'import-linter when import-linter is on'
	: >"$UV_STUB_CALLS"
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 0 ]
	output_is 'upgraded dependency pytest>=9' 'added dependency mutmut' 'removed dependency deptry' \
		'wrote .assay-preset.json'
	holds "$UV_STUB_CALLS" 'add --dev pytest>=9 mutmut' 'remove --dev deptry'
	dev_group >"$T/dev"
	holds "$T/dev" '    "coverage",' '    "hypothesis",' '    "pytest>=9",' '    "mutmut",'
	holds .assay-preset.json '{' '  "python": 2' '}'
}

@test "a dependency the project dropped by hand is not removed again, and one it lacks is added back" {
	python_repo
	"$assay" preset >/dev/null
	UV_STUB_CALLS=/dev/null uv remove --dev deptry
	UV_STUB_CALLS=/dev/null uv remove --dev coverage
	python_version_2 pytest coverage hypothesis
	: >"$UV_STUB_CALLS"
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 0 ]
	output_is 'added dependency coverage' 'wrote .assay-preset.json'
	holds "$UV_STUB_CALLS" 'add --dev coverage'
}

@test "a tool configured in pyproject.toml keeps its section: no file of the preset's beside it, its content shown" {
	python_repo
	printf '%s\n' '' '[tool.ruff.lint]' 'select = ["E"]' '' '[tool.pyright]' 'typeCheckingMode = "basic"' >>pyproject.toml
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[0]}" = 'wrote .coveragerc' ]
	[ "${lines[1]}" = 'wrote conftest.py' ]
	[ "${lines[2]}" = 'kept pyproject.toml [tool.pyright]' ]
	[ "${lines[3]}" = 'kept pyproject.toml [tool.ruff]' ]
	[ ! -e ruff.toml ] && [ ! -e pyrightconfig.json ]
	[[ $output == *$'\n--- pyproject.toml [tool.ruff], kept, against python\'s preset 1\'s ruff.toml (the + lines are the preset\'s)\n+# Every rule ruff has'* ]]
	[[ $output == *$'\n+"**/conftest.py" = ["S101", "PLR2004"]\n'* ]]
	[[ $output == *$'\n+  "typeCheckingMode": "strict",\n'* ]]
	[ "${lines[-1]}" = "pyproject.toml [tool.ruff] holds what python's preset puts in ruff.toml, which it therefore does not write: extend it by hand to hold what ruff.toml holds (the + lines above), in its own syntax" ]
	holds .assay-preset.json '{' '  "python": 1' '}'
	# Extended by hand (or not: assay cannot compare the two), the next run has nothing to do.
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is "python's preset 1: up to date"
}

@test "coverage.py's configuration in setup.cfg, tox.ini or pyproject.toml keeps .coveragerc out" {
	local file
	for file in setup.cfg tox.ini pyproject.toml; do
		python_repo
		case $file in
		pyproject.toml) printf '%s\n' '[tool.coverage.run]' 'branch = true' >>pyproject.toml ;;
		*) printf '%s\n' '[metadata]' 'name = demo' '' '  [coverage:report]' 'show_missing = true' >"$file" ;;
		esac
		run --separate-stderr "$assay" preset
		echo "$output"
		[ "$status" -eq 1 ]
		if [ "$file" = pyproject.toml ]; then
			[ "${lines[0]}" = "kept pyproject.toml [tool.coverage]" ]
		else
			[ "${lines[0]}" = "kept $file [coverage:*]" ]
		fi
		[ ! -e .coveragerc ]
		cd "$T"
		mv "$T/work" "$T/project-$file"
	done
	# A setup.cfg without coverage's sections is not coverage's configuration.
	python_repo
	printf '%s\n' '[metadata]' 'name = demo' >setup.cfg
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = 'wrote .coveragerc' ]
}

@test "ruff reads .ruff.toml before ruff.toml: the preset keeps it and shows it against its ruff.toml" {
	python_repo
	printf '%s\n' '[lint]' 'select = ["E"]' >.ruff.toml
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 1 ]
	[ "${lines[3]}" = 'kept .ruff.toml' ]
	[ ! -e ruff.toml ]
	[[ $output == *$'\n--- .ruff.toml, kept, against python\'s preset 1 (the + lines are the preset\'s)\n'* ]]
}

@test "a later version's change to a file a section stands for is shown as the change between the two versions" {
	python_repo
	printf '%s\n' '' '[tool.ruff]' 'line-length = 100' >>pyproject.toml
	"$assay" preset >/dev/null || true
	python_version_2 pytest coverage hypothesis deptry
	printf '%s\n' '' '[format]' 'quote-style = "single"' >>"$assay_presets/python/2/ruff.toml"
	run --separate-stderr "$assay" preset
	echo "$output"
	[ "$status" -eq 1 ]
	output_is 'kept pyproject.toml [tool.ruff]' 'wrote .assay-preset.json' '' \
		"--- ruff.toml, from python's preset 1 to 2, for pyproject.toml [tool.ruff] (the + lines are 2's)" \
		'@@ -22,3 +22,6 @@ ignore = [' ' "**/*_test.py" = ["S101", "PLR2004"]' ' "**/tests/**" = ["S101", "PLR2004"]' \
		' "**/conftest.py" = ["S101", "PLR2004"]' '+' '+[format]' '+quote-style = "single"' '' \
		"pyproject.toml [tool.ruff] holds what python's preset puts in ruff.toml, which it therefore does not write: make the change above to it by hand, in its own syntax"
	# A version that leaves the file alone shows nothing for it.
	echo '{"python": 1}' >.assay-preset.json
	python_version_2 pytest coverage hypothesis deptry
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is 'wrote .assay-preset.json'
}

@test "without pyproject.toml, assay preset python exits 2 and writes nothing" {
	local_repo
	languages python
	export UV_STUB_CALLS=$T/uv.calls
	run --separate-stderr "$assay" preset python
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: python's preset adds development dependencies to pyproject.toml, which the repo does not have: create the project first (uv init)" ]
	[ ! -e ruff.toml ] && [ ! -e .assay-preset.json ]
	# With no language named, python's preset does not apply.
	run --separate-stderr "$assay" preset
	[ "$status" -eq 0 ]
	output_is "no preset to apply: no language this repo's devenv enables has a preset that applies"
}

@test "without uv, assay preset exits 2 and writes nothing; with nothing to change it does not need uv" {
	python_repo
	local path
	path=$(path_without uv)
	run --separate-stderr env PATH="$path" "$assay" preset
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: cannot find uv on the PATH, which adds python's development dependencies: turn on languages.python.uv.enable in devenv.nix" ]
	[ ! -e ruff.toml ] && [ ! -e .assay-preset.json ]
	"$assay" preset >/dev/null
	run --separate-stderr env PATH="$path" "$assay" preset
	[ "$status" -eq 0 ]
	output_is "python's preset 1: up to date"
}

@test "uv failing is exit 2 with its output, and nothing is written" {
	python_repo
	run --separate-stderr env UV_STUB_FAIL=1 "$assay" preset
	[ "$status" -eq 2 ]
	[ "${stderr_lines[0]}" = "error: No solution found when resolving dependencies" ]
	[ "${stderr_lines[1]}" = "assay: uv add --dev pytest coverage hypothesis deptry failed (exit 1)" ]
	[ -z "$output" ]
	[ ! -e ruff.toml ] && [ ! -e .assay-preset.json ]
}

@test "a pyproject.toml that is not TOML, or a dependency line assay cannot read, is exit 2" {
	python_repo
	echo 'dev = [' >>pyproject.toml
	run --separate-stderr "$assay" preset
	[ "$status" -eq 2 ]
	[[ $stderr == "assay: cannot read pyproject.toml as TOML: "* ]]
	git checkout --quiet pyproject.toml
	python_version_2 pytest 'coverage when' '-x'
	run --separate-stderr "$assay" preset
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: cannot read line 2 of $assay_presets/python/2.dependencies: coverage when" ]
	python_version_2 pytest '-x'
	run --separate-stderr "$assay" preset
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: line 2 of $assay_presets/python/2.dependencies names no package: -x" ]
}
