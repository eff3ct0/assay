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
