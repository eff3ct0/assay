# shellcheck disable=SC2016 # the skill's text and its backquotes are literal
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# The skills assay ships (skills/<name>/SKILL.md), which its home-manager module installs for Claude Code and OpenCode.

skills=$BATS_TEST_DIRNAME/../skills

# frontmatter <file> <field>: a field of a skill's frontmatter.
frontmatter() { awk -v f="$2" 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 && index($0, f ": ") == 1 { print substr($0, length(f) + 3) }' "$1"; }

@test "each skill is named as its directory, which /<name> invokes, and has a description" {
	local dir n=0
	for dir in "$skills"/*/; do
		dir=${dir%/}
		echo "$dir"
		prints "${dir##*/}" frontmatter "$dir/SKILL.md" name
		description=$(frontmatter "$dir/SKILL.md" description)
		[ -n "$description" ]
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
		'`assay rule new <kebab-name> [--lang <lang>] [--from <file>:<line>[-<line>]]`' \
		'a Nix repo, bats in a bash repo). A correction about behaviour that holds for every input becomes a property-based' \
		'test, through `assay-property`.'; do
		if ! grep -qF -- "$part" "$skill"; then
			echo "missing: $part"
			return 1
		fi
	done
	for part in Classify Scaffold Write Test 'Clean up' Commit; do
		grep -q "^[0-9]\. \*\*$part\*\*" "$skill"
	done
}

@test "a skill names no path outside the repo, nor the machine or the user it is tested by" {
	local word
	run grep -n -E '(^|[[:space:]`(])(/[A-Za-z]|~/)|https?:' "$skills"/*/SKILL.md
	echo "$output"
	[ "$status" -eq 1 ]
	for word in "$(uname -n)" "$(id -un)"; do
		if [ ${#word} -lt 4 ]; then continue; fi
		run grep -n -i -w -F -- "$word" "$skills"/*/SKILL.md
		echo "$output"
		[ "$status" -eq 1 ]
	done
}

@test "assay-property's description names its triggers, and its text holds the ladder, the tables, TLA+ and Lean" {
	local skill=$skills/assay-property/SKILL.md part
	description=$(frontmatter "$skill" description)
	for part in \
		'code whose correctness is a rule over all inputs (parsers, serializers, money and other arithmetic, data transformations, state machines)' \
		'code whose correctness depends on the order in which processes, jobs or machines that share state act' \
		'a bug escaped the example tests'; do
		if [[ $description != *"$part"* ]]; then
			echo "missing from the description: $part"
			return 1
		fi
	done
	for part in \
		'1. an example test, the default;' \
		'2. a property-based test: a property holds for every input and can be stated without restating the implementation,' \
		'over a large or structured input space; not when the only property is "returns what the code computes";' \
		'3. a stateful property-based test: one program with an API the test can drive, commands against a model, with a' \
		'scheduler where the library has one (fast-check `fc.commands` with `modelRun` or `scheduledModelRun`,' \
		'`proptest-state-machine`, Hypothesis `RuleBasedStateMachine`, ScalaCheck `Commands` with its parallel `property`);' \
		'4. a TLA+ model: correctness depends on the interleaving of actors that are separate systems (processes, jobs,' \
		'machines sharing a git ref, a database, a queue), on retries or crashes mid-step, or the design is not code yet; it' \
		'pays off before writing a protocol, or after an incident caused by a race;' \
		'5. a Lean proof: a property must hold for unbounded inputs, a failure is costly, and the core is small and pure; the' \
		'proof covers the algorithm, and a property-based test ties the code to the same specification.' \
		'**Forms**: round-trip (`decode (encode x) == x`), invariant, idempotence, oracle (a simple, slow version, or the old' \
		'implementation during a refactor), metamorphic relation (adding a filter never grows the result), stateful model' \
		'- It does not restate the implementation' \
		'- Generators are built from the library'"'"'s combinators over the domain'"'"'s types, not from filters, so that shrinking' \
		'works, and they reach the edges (empty, boundaries, Unicode).' \
		'- One property per test, named by the test.' \
		'- Every counterexample found stays in the repo as an explicit example, in the same commit as the fix.' \
		'| proptest         | `PROPTEST_RNG_SEED=$ASSAY_SEED` in the test check |' \
		'| Hypothesis       | `--hypothesis-profile=ci` in the test check       |' \
		'| fast-check       | `fc.configureGlobal` in `vitest.setup.ts`         |' \
		'| munit-scalacheck | a base trait every property suite extends         | write the trait below ' \
		'override def scalaCheckInitialSeed: String =' \
		'case Some(n) => super.scalaCheckTestParameters.withMinSuccessfulTests(n.toInt)' \
		'| proptest         | `PROPTEST_CASES=10000` and no `PROPTEST_RNG_SEED` ' \
		'| Hypothesis       | `--hypothesis-profile=explore`, with `ASSAY_CASES=10000` ' \
		'| fast-check       | `env -u ASSAY_SEED ASSAY_CASES=10000` before the test command ' \
		'| proptest         | `proptest-regressions/`, committed ' \
		'| Hypothesis       | `@example(...)` on the test; `.hypothesis/` stays ignored ' \
		'| fast-check       | the `examples` parameter of `fc.assert` ' \
		'| munit-scalacheck | a test with the fixed input: a seed stops reproducing once the generators change ' \
		'- **Layout**: `tla/<Name>.tla` with `tla/<Name>.cfg`, at the repo root. A second configuration of a spec is an' \
		'`nix shell nixpkgs#tlaplus18 -c tlc -config <Name>.cfg <Name>.tla`' \
		'- **Budget**: each configuration finishes in under a minute. Shrink the constants rather than grow the budget.' \
		'(`assay.checks.tla.enable = true;`), which brings TLC (`tlaplus18`) into its devenv.' \
		'- Through devenv'"'"'s `languages.lean4.enable` (nixpkgs'"'"' `lean4`, Lake included), with the Lake package in `lean/`.' \
		'- Without elan, `lean-toolchain` is ignored: the version is the devenv'"'"'s.' \
		'- assay gains a `lean` check (`lake build --wfail`, so that a `sorry` fails) with the first Lean case.' \
		'A model'"'"'s or proof'"'"'s header lists the files it abstracts, and each of those files carries a comment naming the model' \
		'Quint (its `verify` downloads Apalache), Apalache (not in nixpkgs), trace validation and model-based test generation.'; do
		if ! grep -qF -- "$part" "$skill"; then
			echo "missing: $part"
			return 1
		fi
	done
	for part in Climb Write Wire Explore Keep Link; do
		grep -q "^[0-9]\. \*\*$part\*\*" "$skill"
	done
}
