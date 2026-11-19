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

@test "collect moves hits once even after commit-before-unlink and permits read-only queries" {
	fixture
	export ASSAY_AGENT=sample
	check bad false
	run "$assay" check --base HEAD
	[ "$status" -eq 1 ]
	cp "$ASSAY_HITS_LOG" "$T/saved"
	collect
	[ ! -e "$ASSAY_HITS_LOG" ]
	batch=$(sql 'select id from batches')
	cp "$T/saved" "$T/$batch"
	cp "$T/saved" "$ASSAY_HITS_LOG"
	collect
	chmod 555 "$T/data"
	chmod 444 "$db"
	actual=$(sql 'pragma journal_mode')
	[ "$actual" = delete ]
	actual=$(sql "select count(*) from failures where name='bad' and agent='sample'")
	[ "$actual" = 2 ]
	chmod 755 "$T/data"
}
