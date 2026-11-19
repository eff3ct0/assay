# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

fixture() {
	export ASSAY_COLLECT_ROOT="$T/root" ASSAY_COLLECT_OWNERS='["one","two"]'
	export ASSAY_HITS_LOG="$T/events" GIT_ALLOW_PROTOCOL=file
	unset ASSAY_RULES
	db=$T/data/metrics.db
	mkdir "$T/data"
	cd "$T" || return 1
	for r in one/example two/local other/ignored one/ignored.wt; do
		git init -q "$ASSAY_COLLECT_ROOT/$r"
		git -C "$ASSAY_COLLECT_ROOT/$r" commit -qm init --allow-empty
	done
	cd "$ASSAY_COLLECT_ROOT/one/example" || return 1
}

collect() { "$assay" collect --db "$db"; }
sql() { sqlite3 -readonly "$db" "$1"; }

@test "collect rebuilds remote first-parent history and leaves main checkout alone" {
	fixture
	git commit --allow-empty -qm 'change (#12)'
	git -c 'user.name=automation[bot]' commit --allow-empty -qm bot
	git switch -qc topic
	git commit --allow-empty -qm 'Revert "something"'
	git switch -q main
	git merge -q --no-ff topic -m 'Merge pull request #3 from topic'
	git init -q --bare "$T/remote"
	git remote add origin "$T/remote"
	git push -q origin main
	git remote set-head origin main
	git switch -qc other HEAD~1
	echo dirty >untracked
	before=$(git status --porcelain && git worktree list)
	collect
	actual=$(sql 'select group_concat(repo) from (select repo from repos order by repo)')
	[ "$actual" = 'one/example,two/local' ]
	actual=$(sql "select count(*),sum(pr),sum(revert) from changes where repo='one/example'")
	[ "$actual" = '3|2|1' ]
	actual=$(sql 'select count(*) from snapshots')
	[ "$actual" = 0 ]
	actual=$(git status --porcelain && git worktree list)
	[ "$actual" = "$before" ]
	tree=$(git rev-parse 'origin/main^{tree}')
	replacement=$(git commit-tree "$tree" -m 'This reverts commit abcdef1234')
	git push -qf origin "$replacement:refs/heads/main"
	collect
	actual=$(sql "select sha,revert from changes where repo='one/example'")
	[ "$actual" = "$replacement|1" ]
	actual=$(git status --porcelain && git worktree list)
	[ "$actual" = "$before" ]
}

@test "collect measures only changed tips and keeps failures null and unadopted repos snapshot-free" {
	fixture
	devenv_files yes
	outside_devenv
	# A repo-pinned measuring command, invoked only from the extracted tree.
	unlink "$DEVENV_STUB_PROFILE/assay"
	printf '#!%s\n' "$BASH" >"$DEVENV_STUB_PROFILE/assay"
	cat >>"$DEVENV_STUB_PROFILE/assay" <<'SH'
[[ $1 = measure && ! -e .git && -f devenv.nix && ! -f fail ]] || exit 2
echo '{"version":1,"seconds":1,"failed":[],"coverage":{},"lint":null,"smells":[],"duplication":null,"loc":[]}'
SH
	chmod +x "$DEVENV_STUB_PROFILE/assay"
	(cd "$ASSAY_COLLECT_ROOT/two/local" && devenv_files no)
	collect
	collect
	actual=$(sql "select count(*),metrics->>'seconds' from snapshots")
	[ "$actual" = '1|1' ]
	actual=$(sql "select state from repos where repo='two/local'")
	[ "$actual" = unadopted ]
	touch fail
	git add fail
	git commit -qm broken
	collect
	collect
	actual=$(sql 'select count(*),count(error),count(metrics) from snapshots')
	[ "$actual" = '2|1|1' ]
	actual=$(wc -l <"$DEVENV_STUB_CALLS")
	[ "$actual" -eq 3 ]
}

@test "a failed check in an archive retains metrics and diagnostic until the tip moves" {
	fixture
	devenv_files yes
	check needs-history 'git rev-parse --verify HEAD'
	outside_devenv
	collect
	collect
	actual=$(sql "select state,metrics->>'seconds' is not null,error from repos join snapshots using(repo,tip)")
	[ "$actual" = 'failed|1|Failed checks: needs-history' ]
	actual=$(wc -l <"$DEVENV_STUB_CALLS")
	[ "$actual" -eq 1 ]
	git commit -qm moved --allow-empty
	collect
	actual=$(sql 'select count(error) from snapshots')
	[ "$actual" = 2 ]
}

@test "hits from an already-open writer arrive once, without waiting for a spool lock" {
	fixture
	export ASSAY_AGENT=sample
	# Compatibility run can supply the actual packaged pre-collector and current writers.
	old=${ASSAY_TEST_OLD_WRITER:-$assay}
	new=${ASSAY_TEST_NEW_WRITER:-$assay}
	# Pause the old writer inside printf, after Bash has opened its append descriptor.
	cat >"$T/pause" <<'SH'
printf() {
	if [[ $1 = '%s\n' && ${2:-} = *'"source":"check"'* ]]; then
		echo ready >"$T/entered"
		read -r _ <"$T/resume"
	fi
	builtin printf "$@"
}
SH
	mkfifo "$T/entered" "$T/resume"
	export T
	BASH_ENV=$T/pause timeout 20 "$old" check --base HEAD 3>&- &
	writer=$!
	read -r _ <"$T/entered"
	collect
	echo continue >"$T/resume"
	wait "$writer"
	(
		flock -x 9
		timeout 5 "$new" check --base HEAD
	) 9>>"$ASSAY_HITS_LOG.lock"
	collect
	collect
	actual=$(sql 'select count(*) from hits')
	[ "$actual" = 2 ]
}

@test "hits cursor waits for newline and commits atomically with imported rows" {
	fixture
	check bad false
	run "$assay" check --base HEAD
	[ "$status" -eq 1 ]
	line=$(cat "$ASSAY_HITS_LOG")
	printf '%s' "$line" >>"$ASSAY_HITS_LOG"
	collect
	actual=$(sql 'select count(*) from hits')
	[ "$actual" = 1 ]
	position=$(sql 'select position from hit_cursors')
	printf '\n' >>"$ASSAY_HITS_LOG"
	# Abort after inserting the second hit, just before committing the new cursor.
	sqlite3 "$db" "create trigger fail before insert on hit_cursors begin select raise(abort,'interrupted'); end;"
	run collect
	[ "$status" -ne 0 ]
	actual=$(sql 'select count(*),position from hits cross join hit_cursors')
	[ "$actual" = "1|$position" ]
	sqlite3 "$db" 'drop trigger fail'
	collect
	collect
	chmod 555 "$T/data"
	chmod 444 "$db"
	actual=$(sql 'pragma journal_mode')
	[ "$actual" = delete ]
	actual=$(sql "select count(*) from failures where name='bad'")
	[ "$actual" = 2 ]
	chmod 755 "$T/data"
}
