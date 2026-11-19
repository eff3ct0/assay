# shellcheck disable=SC2016 # the skill's text and its backquotes are literal
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

# The skills assay ships (skills/<name>/SKILL.md), which its home-manager module installs for Claude Code and OpenCode.

skills=$BATS_TEST_DIRNAME/../skills

# frontmatter <file> <field>: a field of a skill's frontmatter.
frontmatter() { awk -v f="$2" 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 && index($0, f ": ") == 1 { print substr($0, length(f) + 3) }' "$1"; }

@test "each skill is named as its directory, which /<name> invokes, and has a description" {
	local dir n=0
	for dir in "$skills"/*/; do
		dir=${dir%/}
		echo "$dir"
		[ "$(frontmatter "$dir/SKILL.md" name)" = "${dir##*/}" ]
		[ -n "$(frontmatter "$dir/SKILL.md" description)" ]
		n=$((n + 1))
	done
	[ "$n" -ge 1 ]
}

@test "assay-rule holds every part of the procedure" {
	local skill=$skills/assay-rule/SKILL.md part
	for part in \
		'**Correction**: the user telling an agent that something it did must not be done that way again, a standing' \
		'When it cannot tell a correction from steering, it' \
		'| the code of a repo ' '| a code rule in that repo ' \
		'| what an agent does: the commands it runs, the files it edits ' \
		'| a guard rule in the machine'"'"'s rule list (`programs.assay.rules`) ' \
		'| commits and pushes ' '| a `commit-msg` rule in the same list ' \
		'| the machine'"'"'s own system configuration ' '| an expectation in that configuration'"'"'s own checks ' \
		'| something no deterministic check can tell ' '| prose, saying why no check holds it ' \
		'1. by construction (a type, a narrower API, a template);' \
		'2. a lint the linter already has (clippy `unwrap_used`, ESLint `no-explicit-any`, ruff `T201`...);' \
		'3. forbidding a named item through the linter'"'"'s ban list, which resolves imports and aliases: clippy' \
		'4. a dependency between parts of the repo: the boundary tool (dependency-cruiser, import-linter, the crate graph plus' \
		'5. a shape of the code: an ast-grep rule, one format and one test harness for all six languages.' \
		'6. what ast-grep cannot parse (Markdown, the shape of the file tree): a test in the repo'"'"'s own suite (a flake check in' \
		'Severity always `error`; `message`, one line at the location, what is wrong and what to do instead; `note` with' \
		'**Why** (the root cause), **Fix** (the right change, concretely) and **Not a fix** (the known dodges: renaming,' \
		'If the rule is wrong here, stop and tell the user; exceptions go in the rule'"'"'s own file.' \
		'Exceptions live in the rule (`ignores` globs, a `not:` clause), never inline.' \
		'Every ast-grep rule has at least one `invalid` case (the corrected code cut to the minimum) and at least one `valid`' \
		'Existing occurrences are cleaned in the same commit as the rule, so it lands green: the rule'"'"'s `fix:` with' \
		'A code rule is its own commit on the current branch (the rule, its tests and the cleanup), with the correction quoted' \
		'`commit-msg` rule is its own branch `agent/rule-<name>` in the repository that holds the machine'"'"'s configuration, with a' \
		'ast-grep'"'"'s own layout (`sgconfig.yml`, `rules/<name>.yml`, `rule-tests/<name>-test.yml`); native rules in their tool'"'"'s' \
		'A rule is born in the repo where the correction happened, and moves to a pack as above.' \
		'A new correction adds no prose unless no check can hold it; then it goes in the `AGENTS.md` that applies, saying why no' \
		'`assay rule new <kebab-name> [--lang <lang>] [--from <file>:<line>[-<line>]]`'; do
		if ! grep -qF -- "$part" "$skill"; then
			echo "missing: $part"
			return 1
		fi
	done
	for part in Classify Scaffold Write Test 'Clean up' Commit; do
		grep -q "^[0-9]\. \*\*$part\*\*" "$skill"
	done
}

@test "a skill names no machine, person or path outside the repo" {
	run grep -n -i -E '(^|[[:space:]`(])(/[a-z]|~/)|https?:|hefesto|p3rkins|rafafrdz|eff3ct0|nixos-config' "$skills"/*/SKILL.md
	echo "$output"
	[ "$status" -eq 1 ]
}
