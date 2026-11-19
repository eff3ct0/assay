# Shared setup: a throwaway HOME and git config, a configuration written by hand, and repos in a temp directory.

setup() {
	T=$BATS_TEST_TMPDIR
	export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1
	mkdir -p "$HOME"
	# ASSAY_HITS_LOG and ASSAY_AGENT too: the suite, run on a machine that sets them, writes nothing to its log.
	unset ASSAY_CONFIG ASSAY_BASE GITHUB_EVENT_PATH assay_tools ASSAY_HITS_LOG ASSAY_AGENT DEVENV_STUB_FAIL
	git config --global user.name Test
	git config --global user.email test@example.com
	git config --global init.defaultBranch main
	git config --global protocol.file.allow always
	git config --global advice.detachedHead false
	# Detached auto-gc would race the teardown.
	git config --global gc.auto 0
	git config --global maintenance.auto false
	# shellcheck disable=SC2034 # used by the .bats files
	assay=$BATS_TEST_DIRNAME/../assay.sh
	# devenv is the stub in test/stub/; the devenv it stands in for puts this checkout's assay on the PATH.
	export PATH=$BATS_TEST_DIRNAME/stub:$PATH DEVENV_STUB_CALLS=$T/devenv.calls DEVENV_STUB_PROFILE=$T/profile
	mkdir -p "$DEVENV_STUB_PROFILE"
	ln -s "$assay" "$DEVENV_STUB_PROFILE/assay"
	no_checks
}

# outside_devenv: what follows runs as from a shell outside the repo's devenv: ASSAY_CONFIG unset, and the
# configuration handed to the stub's devenv instead.
outside_devenv() {
	export DEVENV_STUB_CONFIG=$ASSAY_CONFIG
	unset ASSAY_CONFIG
}

# devenv_files <imports assay: yes|no>: commit a devenv.nix and a devenv.yaml, which imports assay/devenv or not.
devenv_files() {
	echo '{ }' >devenv.nix
	if [ "$1" = yes ]; then
		printf '%s\n' 'inputs:' '  assay:' '    url: github:eff3ct0/assay' '    flake: false' 'imports:' '  - assay/devenv' \
			>devenv.yaml
	else
		printf '%s\n' 'inputs:' '  nixpkgs:' '    url: github:cachix/devenv-nixpkgs/rolling' >devenv.yaml
	fi
	git add devenv.nix devenv.yaml
	git commit --quiet -m devenv
}

# no_checks: an empty configuration, pointed at by ASSAY_CONFIG.
no_checks() {
	export ASSAY_CONFIG=$T/config.json
	echo '{"version": 1, "checks": {}, "coverage": {"newCode": 80}, "loosenings": []}' >"$ASSAY_CONFIG"
}

# check <name> <exec> [--fast] [--off] [--requires <glob>] [--coverage <path>]: add a check to the configuration.
check() {
	local name=$1 exec=$2 fast=false enable=true requires=null coverage=null
	shift 2
	while [ $# -gt 0 ]; do
		case $1 in
		--fast) fast=true ;;
		--off) enable=false ;;
		--requires)
			requires=$(jq -n --arg r "$2" '$r')
			shift
			;;
		--coverage)
			coverage=$(jq -n --arg c "$2" '$c')
			shift
			;;
		esac
		shift
	done
	jq --arg n "$name" --arg e "$exec" --argjson f "$fast" --argjson on "$enable" --argjson r "$requires" \
		--argjson c "$coverage" '.checks[$n] = {exec: $e, fast: $f, enable: $on, requires: $r, coverage: $c}' \
		"$ASSAY_CONFIG" >"$ASSAY_CONFIG.new"
	mv "$ASSAY_CONFIG.new" "$ASSAY_CONFIG"
}

# new_code <percent>: the configuration's coverage threshold for new code.
new_code() {
	jq --argjson p "$1" '.coverage.newCode = $p' "$ASSAY_CONFIG" >"$ASSAY_CONFIG.new"
	mv "$ASSAY_CONFIG.new" "$ASSAY_CONFIG"
}

# loosening <check> <kind> <reason>: add a loosening to the configuration.
loosening() {
	jq --arg c "$1" --arg k "$2" --arg r "$3" '.loosenings += [{check: $c, kind: $k, reason: $r}]' \
		"$ASSAY_CONFIG" >"$ASSAY_CONFIG.new"
	mv "$ASSAY_CONFIG.new" "$ASSAY_CONFIG"
}

# commit_file <dir> <file> [content]: add and commit a file.
commit_file() {
	echo "${3:-$2}" >"$1/$2"
	git -C "$1" add "$2"
	git -C "$1" commit --quiet -m "add $2"
}

# upstream: a "GitHub" repo with two commits on main ($T/up, a working copy, pushes to $T/origin.git), cloned into
# $T/work, the current directory.
upstream() {
	git init --quiet "$T/up"
	commit_file "$T/up" a.txt
	commit_file "$T/up" b.txt
	git clone --quiet --bare "$T/up" "$T/origin.git"
	git -C "$T/up" remote add origin "$T/origin.git"
	git -C "$T/up" fetch --quiet origin
	git clone --quiet "$T/origin.git" "$T/work"
	cd "$T/work" || return 1
}

# local_repo: a repo with one commit and no remote, the current directory.
local_repo() {
	git init --quiet "$T/work"
	commit_file "$T/work" a.txt
	cd "$T/work" || return 1
}

# sha <rev> [dir]
sha() { git -C "${2:-.}" rev-parse "$1"; }
short() { git -C "${2:-.}" rev-parse --short "$1"; }

# builtin_checks <setup>: the configuration assay's devenv module writes for a devenv setup, test/defaults/<setup>.json
# (plain, javascript or javascript-frontend; nix flake check compares each with the module's), with this checkout's
# assay on the PATH for the checks that call it.
builtin_checks() {
	export ASSAY_CONFIG=$BATS_TEST_DIRNAME/defaults/$1.json
	PATH=$DEVENV_STUB_PROFILE:$PATH
}

# shaped_repo: a repo with one commit that every built-in check passes, as the current directory.
shaped_repo() {
	local_repo
	printf '%s\n' '# repo' '' '## Related repos' '' '- Depends on: none.' >AGENTS.md
	echo '@AGENTS.md' >CLAUDE.md
	mkdir -p .github/workflows
	printf '%s\n' 'name: check' 'on:' '  push:' 'jobs:' '  check:' '    runs-on: ubuntu-latest' '    steps:' \
		'      - run: echo ok' >.github/workflows/check.yml
	git add -A
	git commit --quiet -m shaped
}

# example_rules [<name>...]: RULES, the example rule list test/rules/example.json (the home-manager module renders it
# from test/rules/example.nix), or a copy with only the rules named.
example_rules() {
	RULES=$BATS_TEST_DIRNAME/rules/example.json
	if [ $# -gt 0 ]; then
		jq --args '.rules |= map(select(.name | IN($ARGS.positional[])))' "$@" <"$RULES" >"$T/rules.json"
		RULES=$T/rules.json
	fi
}

# checkouts: $T/origin.git, a bare remote whose default branch is main; $T/repo, its clone, a main checkout on main
# with one commit, pushed; $T/worktree, a linked worktree of it on agent/example, pushed with its upstream set; and
# $T/local, a repo with one commit and no remote.
checkouts() {
	git init --quiet --bare "$T/origin.git"
	git clone --quiet "$T/origin.git" "$T/repo" 2>/dev/null
	commit_file "$T/repo" README.md "# repo"
	git -C "$T/repo" push --quiet origin main
	git -C "$T/repo" worktree add --quiet "$T/worktree" -b agent/example
	git -C "$T/worktree" push --quiet -u origin agent/example 2>/dev/null
	git init --quiet "$T/local"
	commit_file "$T/local" README.md "# local"
}

# config_set <jq filter> [<jq argument>...]: the configuration, rewritten by the filter into a copy in $T, which
# ASSAY_CONFIG then names.
config_set() {
	local filter=$1
	shift
	jq "$filter" "$@" <"$ASSAY_CONFIG" >"$T/config-set.next"
	mv "$T/config-set.next" "$T/config-set.json"
	export ASSAY_CONFIG=$T/config-set.json
}

# sg_project: an ast-grep project at the current directory, as `assay rule new` lays one out: test/projects/no-eval
# (sgconfig.yml, the rule no-eval, bash's eval, in rules/ and its tests in rule-tests/), and a script it passes.
sg_project() {
	cp -r "$BATS_TEST_DIRNAME/projects/no-eval/." .
	echo 'run() { "$@"; }' >script.sh
}

# rule_packs <name>...: the configuration with the rule packs of test/packs/ named turned on, as assay's devenv module
# writes them.
rule_packs() {
	# shellcheck disable=SC2016 # jq's variables, not the shell's
	config_set '.rulePacks = (reduce $ARGS.positional[] as $p ({}; .[$p] = "\($dir)/\($p)"))' \
		--arg dir "$BATS_TEST_DIRNAME/packs" --args "$@"
}
