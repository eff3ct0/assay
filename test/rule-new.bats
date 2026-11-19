# shellcheck disable=SC2016 # the fixtures' scripts and rules, and the messages' backquotes, are literal text
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# assay rule new <kebab-name> [--lang <lang>] [--from <file>:<line>[-<line>]]: an ast-grep rule's scaffold, written in
# ast-grep's own layout, whose placeholders fail the ast-grep check until they are filled in.

# languages <language>...: the languages the configuration says the repo enables.
languages() { config_set '.languages = $ARGS.positional' --args "$@"; }

# yaml <file> <yq expression>: the value, as compact JSON.
yaml() { yq -o=json -I=0 "$2" "$1"; }

# rust_source: src/a.rs, whose third line reads configuration from the environment.
rust_source() {
	mkdir -p src
	printf '%s\n' 'fn main() {' '    let name = "x";' '    let home = std::env::var("HOME");' '}' >src/a.rs
}

@test "rule new --from: prints what it created; sgconfig.yml holds relative paths; the first invalid case is the line" {
	local_repo
	rust_source
	run --separate-stderr "$assay" rule new no-env-var --from src/a.rs:3
	echo "$output$stderr"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' sgconfig.yml rules/no-env-var.yml rule-tests/no-env-var-test.yml)" ]
	[ -z "$stderr" ]
	prints '["rules"]' yaml sgconfig.yml .ruleDirs
	prints '[{"testDir":"rule-tests"}]' yaml sgconfig.yml .testConfigs
	prints '"no-env-var"' yaml rule-tests/no-env-var-test.yml .id
	prints '"let home = std::env::var(\"HOME\");\n"' yaml rule-tests/no-env-var-test.yml '.invalid[0]'
	prints '["no-env-var","rust","error"]' yaml rules/no-env-var.yml '[.id, .language, .severity]'
	# The note's skeleton: Why, Fix, Not a fix, and the closing line.
	note=$(yq '.note' rules/no-env-var.yml)
	[[ $note == "Why: "*$'\nFix: '*$'\nNot a fix: '*$'\nIf the rule is wrong here, stop and tell the user; exceptions go in the rule'"'"'s own file.' ]]
}

@test "right after scaffolding the ast-grep check fails on the placeholders; filled in, it passes" {
	local_repo
	builtin_checks plain
	rust_source
	"$assay" rule new no-env-var --from src/a.rs:3 >/dev/null
	run --separate-stderr "$assay" check --base HEAD ast-grep oxfmt
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *$'\nok   oxfmt '* ]]
	[[ $output == *$'\nrules/no-env-var.yml:'[0-9]*':message: "<fill in: '* ]]
	[[ $output == *$'\nrules/no-env-var.yml:'[0-9]*':  pattern: "<fill in: '* ]]
	[[ $output == *$'\nrule-tests/no-env-var-test.yml:'[0-9]*':  - "<fill in: the fix>"'* ]]
	[[ $output == *" placeholders of assay rule new left in the rules and their tests: fill each one in"* ]]
	# Filled in: a rule that matches, its message and note, a fix and a near miss.
	sed -i -e 's/"<fill in: what is wrong and what to do instead>"/Read configuration through `Settings`, not `std::env::var`./' \
		-e 's/<fill in: the root cause>/the environment is read in one place./' \
		-e 's/<fill in: the right change>/`Settings::load()`./' \
		-e 's/<fill in: the known dodges>/an alias of `std::env`, or `var_os`./' \
		-e 's/"<fill in: the shape of the corrected code>"/std::env::var($NAME)/' rules/no-env-var.yml
	sed -i -e 's/"<fill in: the fix>"/let home = settings.home;/' \
		-e "s/\"<fill in: a near miss>\"/let s = \"std::env::var\";/" rule-tests/no-env-var-test.yml
	run --separate-stderr "$assay" check --base HEAD ast-grep oxfmt
	echo "$output"
	[ "$status" -eq 1 ]
	[[ $output == *"error[no-env-var]: Read configuration through \`Settings\`, not \`std::env::var\`."* ]]
	[[ $output == *"src/a.rs:3:"* ]]
	# The existing occurrence cleaned up in the same change.
	sed -i 's/std::env::var("HOME")/settings.home/' src/a.rs
	run --separate-stderr "$assay" check --base HEAD ast-grep oxfmt
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "without --from, the first invalid case is a placeholder too" {
	local_repo
	languages bash
	run --separate-stderr "$assay" rule new no-eval
	[ "$status" -eq 0 ]
	prints '["<fill in: the corrected code, cut down to the minimum>"]' yaml rule-tests/no-eval-test.yml '.invalid'
	prints '"bash"' yaml rules/no-eval.yml .language
}

@test "a rule of that name that already exists: exit 1, nothing written" {
	local_repo
	languages rust
	"$assay" rule new no-env-var >/dev/null
	run --separate-stderr "$assay" rule new no-env-var
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ "$stderr" = "assay: a rule named no-env-var already exists: rules/no-env-var.yml" ]
	# A rule of that id in a file of another name, or its tests alone.
	mv rules/no-env-var.yml rules/env.yml
	run --separate-stderr "$assay" rule new no-env-var
	[ "$status" -eq 1 ]
	[ "$stderr" = "assay: a rule named no-env-var already exists: rule-tests/no-env-var-test.yml" ]
	rm rule-tests/no-env-var-test.yml
	run --separate-stderr "$assay" rule new no-env-var
	[ "$status" -eq 1 ]
	[ "$stderr" = "assay: a rule named no-env-var already exists: rules/env.yml" ]
	find . -path ./.git -prune -o -type f -print >"$T/files"
	files=$(wc -l <"$T/files")
	[ "$files" -eq 3 ]
}

@test "the language: --lang, else --from's file, else the repo's single enabled language, else exit 2 asking for it" {
	local_repo
	rust_source
	printf '%s\n' '#!/usr/bin/env bash' 'eval "$1"' >run
	printf '%s\n' 'x = 1' >tool.py
	printf '%s\n' 'x' >notes.txt
	printf '%s\n' 'package main' >x.go
	printf '%s\n' 'const a = 1;' | tee c.ts y.mjs z.tsx >/dev/null
	printf '%s\n' '{ a = 1; }' >m.nix
	printf '%s\n' 'object A' >s.scala
	printf '%s\n' 'echo a' >t.sh
	languages python rust
	run --separate-stderr "$assay" rule new a
	[ "$status" -eq 2 ]
	[ -z "$output" ]
	[ "$stderr" = "assay: rule new needs --lang <language>: the repo enables several of assay's languages (python, rust)" ]
	[ ! -e sgconfig.yml ]
	run --separate-stderr "$assay" rule new a --from notes.txt:1
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: rule new needs --lang <language>: ast-grep gives notes.txt no language, and the repo enables several (python, rust)" ]
	"$assay" rule new b --from src/a.rs:3 >/dev/null
	"$assay" rule new c --from tool.py:1 >/dev/null
	"$assay" rule new d --from run:2 >/dev/null
	"$assay" rule new e --from src/a.rs:3 --lang Scala >/dev/null
	"$assay" rule new f --lang=tsx >/dev/null
	# ast-grep's language for the file, whichever languages the repo enables.
	"$assay" rule new go --from x.go:1 >/dev/null
	"$assay" rule new ts --from c.ts:1 >/dev/null
	"$assay" rule new mjs --from y.mjs:1 >/dev/null
	"$assay" rule new tsx --from z.tsx:1 >/dev/null
	"$assay" rule new nix --from m.nix:1 >/dev/null
	"$assay" rule new scala --from s.scala:1 >/dev/null
	"$assay" rule new sh --from t.sh:1 >/dev/null
	languages rust
	"$assay" rule new g >/dev/null
	"$assay" rule new h --from notes.txt:1 >/dev/null
	for r in b:rust c:python d:bash e:Scala f:tsx g:rust h:rust go:go ts:typescript mjs:javascript tsx:tsx nix:nix \
		scala:scala sh:bash; do
		prints "${r#*:}" yq '.language' "rules/${r%%:*}.yml"
	done
	languages
	run --separate-stderr "$assay" rule new i
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: rule new needs --lang <language>: the repo enables none of assay's languages" ]
}

@test "usage: exit 2, writing nothing" {
	local_repo
	languages rust
	rust_source
	for args in "rule" "rule old" "rule new" "rule new NoEnv" "rule new no-env-" "rule new no--env" "rule new a b" \
		"rule new a --lang" "rule new a --lang c++" "rule new a --from" "rule new a --from src/a.rs" \
		"rule new a --from src/a.rs:0" "rule new a --from src/a.rs:3-2" "rule new a --from src/a.rs:x" \
		"rule new a --from src/a.rs:5" "rule new a --from src/a.rs:4-5" "rule new a --from src/b.rs:1" \
		"rule new a --from src/a.rs:4" "rule new a --nope" "rule new a --from=" "rule new a --lang="; do
		# shellcheck disable=SC2086 # each case's words
		run --separate-stderr "$assay" $args
		echo "$args: $status $stderr"
		if [ "$args" = "rule new a --from src/a.rs:4" ]; then
			[ "$status" -eq 0 ]
			rm -r sgconfig.yml rules rule-tests
			continue
		fi
		[ "$status" -eq 2 ]
		[ -z "$output" ]
		[[ $stderr == "assay: "* ]]
	done
	[ ! -e sgconfig.yml ] && [ ! -e rules ] && [ ! -e rule-tests ]
	run --separate-stderr "$assay" rule new a --from src/a.rs:9
	[ "$stderr" = "assay: --from: src/a.rs has 4 lines, not 9" ]
	printf '%s\n' '' '   ' >blank.rs
	run --separate-stderr "$assay" rule new a --from blank.rs:1-2
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: --from: lines 1-2 of blank.rs are blank" ]
}

@test "an existing sgconfig.yml: the rule goes into its first rule directory and its tests into its first test directory" {
	local_repo
	languages rust
	printf '%s\n' '# ours' 'ruleDirs: [lint/rules, more]' 'testConfigs:' '  - testDir: lint/tests' >sgconfig.yml
	cp sgconfig.yml "$T/before"
	run --separate-stderr "$assay" rule new no-env-var
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' lint/rules/no-env-var.yml lint/tests/no-env-var-test.yml)" ]
	cmp sgconfig.yml "$T/before"
	first=$(head -1 lint/tests/no-env-var-test.yml)
	[[ $first == "# The tests of lint/rules/no-env-var.yml, "* ]]
	# A rule of that id in another of its rule directories.
	mkdir more
	printf '%s\n' 'id: "no-unwrap" # existing' 'language: rust' >more/x.yml
	run --separate-stderr "$assay" rule new no-unwrap
	[ "$status" -eq 1 ]
	[ "$stderr" = "assay: a rule named no-unwrap already exists: more/x.yml" ]
	# One that names no test directory: the tests would never run.
	printf '%s\n' 'ruleDirs: [lint/rules]' >sgconfig.yml
	run --separate-stderr "$assay" rule new other
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: sgconfig.yml names no test directory (testConfigs: - testDir: <dir>), where the rule's tests would go" ]
	printf '%s\n' 'testConfigs: [{testDir: t}]' >sgconfig.yml
	run --separate-stderr "$assay" rule new other
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: sgconfig.yml names no rule directory (ruleDirs), where the rule would go" ]
	printf '%s\n' 'ruleDirs: [' >sgconfig.yml
	run --separate-stderr "$assay" rule new other
	[ "$status" -eq 2 ]
	[[ $stderr == "assay: sgconfig.yml cannot be read as YAML: "* ]]
}

@test "--from's lines are dedented into a block; a first line deeper than the rest becomes a quoted string" {
	local_repo
	printf '%s\n' 'def f(x):' '    if x:' '        g(x,   ' '' '            "a\tb")' '    return x' >m.py
	"$assay" rule new a --from m.py:2-5 >/dev/null
	prints '"if x:\n    g(x,\n\n        \"a\\tb\")\n"' yaml rule-tests/a-test.yml '.invalid[0]'
	grep -qx '  - |' rule-tests/a-test.yml
	"$assay" rule new b --from m.py:3-6 >/dev/null
	prints '"    g(x,\n\n        \"a\\tb\")\nreturn x\n"' yaml rule-tests/b-test.yml '.invalid[0]'
	run ! grep -qx '  - |' rule-tests/b-test.yml
	printf 'a\r\nb\r\n' >crlf.py
	"$assay" rule new c --from crlf.py:1-2 >/dev/null
	prints '"a\r\nb\r\n"' yaml rule-tests/c-test.yml '.invalid[0]'
	# Every one of them passes the built-in oxfmt check.
	builtin_checks plain
	run --separate-stderr "$assay" check --base HEAD oxfmt
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "from a subdirectory, --from's path and the paths it prints are relative to it" {
	local_repo
	rust_source
	cd src
	run --separate-stderr "$assay" rule new no-env-var --from a.rs:3
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' ../sgconfig.yml ../rules/no-env-var.yml ../rule-tests/no-env-var-test.yml)" ]
	[ -f ../rules/no-env-var.yml ]
	prints '"let home = std::env::var(\"HOME\");\n"' yaml ../rule-tests/no-env-var-test.yml '.invalid[0]'
	run --separate-stderr "$assay" rule new other --from=a.rs:2-3
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' ../rules/other.yml ../rule-tests/other-test.yml)" ]
	prints '"let name = \"x\";\nlet home = std::env::var(\"HOME\");\n"' yaml ../rule-tests/other-test.yml '.invalid[0]'
}

@test "--help prints the usage and exits 0" {
	local_repo
	for args in "rule --help" "rule new --help" "rule new -h"; do
		# shellcheck disable=SC2086 # each case's words
		run --separate-stderr "$assay" $args
		[ "$status" -eq 0 ]
		[[ $output == *"assay rule new <kebab-name> [--lang <lang>] [--from <file>:<line>[-<line>]]"* ]]
	done
	[ ! -e sgconfig.yml ]
}

@test "an sgconfig.yml naming absolute directories: inside the repo the paths print relative, outside it absolute" {
	local_repo
	languages rust
	printf '%s\n' "ruleDirs: [$PWD/lint]" "testConfigs: [{testDir: $T/elsewhere/tests}]" >sgconfig.yml
	run --separate-stderr "$assay" rule new no-env-var
	echo "$stderr"
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '%s\n' lint/no-env-var.yml "$T/elsewhere/tests/no-env-var-test.yml")" ]
	[ -f "$T/elsewhere/tests/no-env-var-test.yml" ]
}

@test "a file it cannot write: exit 2" {
	local_repo
	languages rust
	mkdir rules
	chmod a-w rules
	run --separate-stderr "$assay" rule new no-env-var
	chmod u+w rules
	[ "$status" -eq 2 ]
	[ -z "$output" ]
	[[ $stderr == *"assay: cannot write rules/no-env-var.yml" ]]
}
