# shellcheck disable=SC2030,SC2031 # bats runs each test in a process of its own: what one test sets, no other reads
# shellcheck source=test/helpers.bash
source "$BATS_TEST_DIRNAME/helpers.bash"

# The base of the change, as the header shows it: "<label>@<short sha> (<source>)" or "<short sha> (<source>)".
base_of_run() {
	run "$assay" check "$@"
	[ "$status" -eq 0 ]
	base=${lines[0]#* · base }
}

# event <file> <json>: a GitHub event file, pointed at by GITHUB_EVENT_PATH.
event() {
	echo "$2" >"$T/$1"
	export GITHUB_EVENT_PATH=$T/$1
}

@test "--base comes first" {
	upstream
	event pr.json "{\"pull_request\": {\"base\": {\"sha\": \"$(sha HEAD)\"}}}"
	export ASSAY_BASE=HEAD
	base_of_run --base HEAD~1
	[ "$base" = "HEAD~1@$(short HEAD~1) (--base)" ]
}

@test "ASSAY_BASE comes before GitHub's event" {
	upstream
	event pr.json "{\"pull_request\": {\"base\": {\"sha\": \"$(sha HEAD)\"}}}"
	export ASSAY_BASE=HEAD~1
	base_of_run
	[ "$base" = "HEAD~1@$(short HEAD~1) (ASSAY_BASE)" ]
}

@test "on a pull request, the base is pull_request.base.sha" {
	upstream
	event pr.json "{\"before\": \"$(sha HEAD)\", \"pull_request\": {\"base\": {\"sha\": \"$(sha HEAD~1)\"}}}"
	base_of_run
	[ "$base" = "$(short HEAD~1) (pull_request event)" ]
}

@test "on a push, the base is before" {
	upstream
	event push.json "{\"before\": \"$(sha HEAD~1)\", \"after\": \"$(sha HEAD)\"}"
	base_of_run
	[ "$base" = "$(short HEAD~1) (push event)" ]
}

@test "a push that created the branch (before all zeros) falls through to fork-point" {
	upstream
	event push.json '{"before": "0000000000000000000000000000000000000000"}'
	base_of_run
	[ "$base" = "origin/main@$(short origin/main) (fork-point)" ]
}

@test "an event with no base falls through to fork-point" {
	upstream
	event dispatch.json '{"inputs": {}}'
	base_of_run
	[ "$base" = "origin/main@$(short origin/main) (fork-point)" ]
}

@test "an unreadable GitHub event exits 2" {
	upstream
	export GITHUB_EVENT_PATH=$T/missing.json
	run "$assay" check
	[ "$status" -eq 2 ]
	[[ $output == "assay: cannot read GitHub's event "* ]]
	event broken.json '{"before":'
	run "$assay" check
	[ "$status" -eq 2 ]
}

@test "fork-point: a commit the upstream dropped after the branch was cut stays out of the change" {
	upstream
	# Upstream main: a, b. The branch is cut from b, then upstream rewrites main to a, c, dropping b.
	git switch --quiet -c topic
	commit_file . topic.txt
	cut=$(sha origin/main)
	git -C "$T/up" reset --quiet --hard HEAD~1
	commit_file "$T/up" c.txt
	git -C "$T/up" push --quiet --force origin main
	git fetch --quiet origin
	check change "git diff --name-only \"\$ASSAY_BASE\" >$T/change"
	base_of_run
	[ "$base" = "origin/main@$(short "$cut") (fork-point)" ]
	[ "$(cat "$T/change")" = topic.txt ]
	# The plain merge base would have put the dropped commit's file into the change.
	[ "$(git diff --name-only "$(git merge-base origin/main HEAD)")" = "$(printf 'b.txt\ntopic.txt')" ]
}

@test "merge-base: when fork-point finds nothing, the plain merge base" {
	upstream
	git switch --quiet -c topic HEAD~1
	commit_file . topic.txt
	# origin/main's reflog only knows its tip, which is not an ancestor of HEAD: fork-point finds nothing.
	base_of_run
	[ "$base" = "origin/main@$(short HEAD~1) (merge-base)" ]
}

@test "on the default branch, the base is the remote's tip: unpushed commits are the change" {
	upstream
	commit_file . unpushed.txt
	base_of_run
	[ "$base" = "origin/main@$(short origin/main) (fork-point)" ]
	[ "$(sha origin/main)" = "$(sha HEAD~1)" ]
}

@test "the default branch is origin/HEAD's target first" {
	upstream
	git -C "$T/up" switch --quiet -c develop HEAD~1
	git -C "$T/up" push --quiet origin develop
	git fetch --quiet origin
	git remote set-head origin develop
	base_of_run
	[ "$base" = "origin/develop@$(short origin/develop) (fork-point)" ]
}

@test "without origin/HEAD the default branch is origin/main, then origin/master" {
	upstream
	git remote set-head origin --delete
	base_of_run
	[ "$base" = "origin/main@$(short origin/main) (fork-point)" ]
	git -C "$T/up" push --quiet origin main:master
	git fetch --quiet origin
	git update-ref -d refs/remotes/origin/main
	base_of_run
	[ "$base" = "origin/master@$(short origin/master) (fork-point)" ]
}

@test "without a remote the default branch is local main, then master" {
	local_repo
	git switch --quiet -c topic
	commit_file . topic.txt
	base_of_run
	[ "$base" = "main@$(short main) (fork-point)" ]
	git branch --quiet -m main master
	base_of_run
	[ "$base" = "master@$(short master) (fork-point)" ]
}

@test "with no default branch assay exits 2, asking for --base" {
	local_repo
	git branch --quiet -m main trunk
	run "$assay" check
	[ "$status" -eq 2 ]
	[[ $output == "assay: no base for the change: "*"pass --base <rev>" ]]
}

@test "with no shared history assay exits 2, asking for --base" {
	upstream
	git switch --quiet --orphan unrelated
	commit_file . other.txt
	run "$assay" check
	[ "$status" -eq 2 ]
	[[ $output == "assay: no base for the change: HEAD shares no commit with origin/main; pass --base <rev>" ]]
}

@test "a base missing from a shallow clone exits 2, and nothing is fetched" {
	upstream
	old=$(sha HEAD~1)
	cd "$T"
	git clone --quiet --depth 1 "file://$T/origin.git" shallow
	cd shallow
	run "$assay" check --base "$old"
	[ "$status" -eq 2 ]
	[[ $output == "assay: base '$old' (from --base) is not a commit in this clone, and assay never fetches:"* ]]
	export ASSAY_BASE=$old
	run "$assay" check
	[ "$status" -eq 2 ]
	unset ASSAY_BASE
	event pr.json "{\"pull_request\": {\"base\": {\"sha\": \"$old\"}}}"
	run "$assay" check
	[ "$status" -eq 2 ]
	[[ $output == *"(from pull_request event)"* ]]
	[ "$(git rev-parse --is-shallow-repository)" = true ]
	run git cat-file -e "$old^{commit}"
	[ "$status" -ne 0 ]
}

@test "assay never fetches: the remote's new commits stay out" {
	upstream
	before=$(sha origin/main)
	commit_file "$T/up" new.txt
	git -C "$T/up" push --quiet origin main
	base_of_run
	[ "$(sha origin/main)" = "$before" ]
	[ "$base" = "origin/main@$(short "$before") (fork-point)" ]
}
