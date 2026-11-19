bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# New code: the lines a change adds or modifies, from the base's tree to the working tree, untracked files included.
# `assay new-code` prints it as one JSON object, {"<path>": [[first, last], ...]}.

# new_code [<arg>...]: run assay new-code, which must exit 0, and leave its JSON, keys sorted, in $json.
new_code() {
	run --separate-stderr "$assay" new-code "$@"
	echo "$stderr"
	[ "$status" -eq 0 ]
	json=$(jq -cS . <<<"$output")
}

# lines <file> <n>: write lines 1..n to file.
lines() { seq 1 "$2" >"$1"; }

@test "new code: committed, staged, unstaged and untracked lines since the base" {
	local_repo
	lines f.txt 5
	git add f.txt
	git commit --quiet -m five
	git switch --quiet -c topic
	sed -i '2s/.*/two/' f.txt
	git commit --quiet -am "line 2"
	lines staged.txt 2
	git add staged.txt
	sed -i '4s/.*/four/' f.txt
	echo 6 >>f.txt
	lines untracked.txt 3
	git rm --quiet a.txt
	new_code --base main
	[ "$json" = '{"f.txt":[[2,2],[4,4],[6,6]],"staged.txt":[[1,2]],"untracked.txt":[[1,3]]}' ]
}

@test "no change is no new code" {
	local_repo
	new_code --base HEAD
	[ "$json" = '{}' ]
}

@test "a renamed file's new code is the lines it changed; a binary, an ignored or a deleted file adds none" {
	local_repo
	lines f.txt 5
	echo 'ignored.txt' >.gitignore
	git add f.txt .gitignore
	git commit --quiet -m five
	git mv f.txt g.txt
	sed -i '3s/.*/three/' g.txt
	printf '\000\001\002' >blob.bin
	lines ignored.txt 4
	git rm --quiet a.txt
	new_code --base HEAD
	[ "$json" = '{"g.txt":[[3,3]]}' ]
}

@test "a removal leaves the lines around it alone; lines split by an unchanged one are two ranges" {
	local_repo
	lines f.txt 6
	git add f.txt
	git commit --quiet -m six
	sed -i -e '2d' -e '4s/.*/x/' -e '5s/.*/y/' f.txt
	printf '%s\n' 1 3 x y 6 | diff - f.txt
	sed -i '1s/.*/one/' f.txt
	new_code --base HEAD
	[ "$json" = '{"f.txt":[[1,1],[3,4]]}' ]
}

@test "paths with spaces, quotes, backslashes, tabs and non-ASCII characters come out as they are" {
	local_repo
	for f in 'a b.txt' '"q".txt' 'b\s.txt' $'t\tab.txt' 'é.txt' '-dash.txt' '*.txt'; do
		echo x >"$f"
	done
	git add -- 'a b.txt' '"q".txt'
	git commit --quiet -m "two"
	echo y >>'a b.txt'
	echo y >>'"q".txt'
	new_code --base HEAD~1
	expected=$(jq -cS -n '{"a b.txt": [[1,2]], "\"q\".txt": [[1,2]], "b\\s.txt": [[1,1]], "t\tab.txt": [[1,1]],
    "é.txt": [[1,1]], "-dash.txt": [[1,1]], "*.txt": [[1,1]]}')
	[ "$json" = "$expected" ]
}

@test "the base: --base, else ASSAY_BASE, else the fork point, as assay check" {
	upstream
	commit_file . c.txt
	echo d >d.txt
	new_code
	[ "$json" = '{"c.txt":[[1,1]],"d.txt":[[1,1]]}' ]
	ASSAY_BASE=HEAD new_code
	[ "$json" = '{"d.txt":[[1,1]]}' ]
	ASSAY_BASE=HEAD new_code --base HEAD~2
	[ "$json" = '{"b.txt":[[1,1]],"c.txt":[[1,1]],"d.txt":[[1,1]]}' ]
	run --separate-stderr "$assay" new-code --base nope
	[ "$status" -eq 2 ]
	[[ $stderr == "assay: base 'nope' (from --base) is not a commit in this clone"* ]]
}

@test "assay new-code leaves the index, the working tree and the object store as they were" {
	local_repo
	echo staged >s.txt
	git add s.txt
	echo untracked >u.txt
	echo more >>a.txt
	index=$(git rev-parse --git-path index)
	before=$(
		git status --porcelain=v2 -uall
		sha256sum <"$index"
	)
	objects=$(git count-objects -v)
	new_code --base HEAD
	[ "$json" = '{"a.txt":[[2,2]],"s.txt":[[1,1]],"u.txt":[[1,1]]}' ]
	index=$(git rev-parse --git-path index)
	after=$(
		git status --porcelain=v2 -uall
		sha256sum <"$index"
	)
	[ "$after" = "$before" ]
	objects_after=$(git count-objects -v)
	[ "$objects_after" = "$objects" ]
	git_dir=$(git rev-parse --absolute-git-dir)
	left=$(ls "$git_dir/assay" 2>/dev/null || true)
	[ -z "$left" ]
}

@test "a check run by assay check sees the same new code through ASSAY_BASE" {
	upstream
	commit_file . c.txt
	check new "\"$assay\" new-code >$T/new.json"
	run "$assay" check
	[ "$status" -eq 0 ]
	seen=$(jq -cS . "$T/new.json")
	[ "$seen" = '{"c.txt":[[1,1]]}' ]
}

@test "in a linked worktree, new code reads that worktree's index and files" {
	local_repo
	git worktree add --quiet "$T/wt" -b topic
	cd "$T/wt"
	echo more >>a.txt
	echo new >n.txt
	new_code --base main
	[ "$json" = '{"a.txt":[[2,2]],"n.txt":[[1,1]]}' ]
	cd "$T/work"
	new_code --base main
	[ "$json" = '{}' ]
}

@test "the user's diff configuration changes nothing: rename limit, order file, algorithm, context, prefixes" {
	local_repo
	{
		echo 'keep'
		seq 1 20
	} >old.txt
	printf '%s\n' a b >z.txt
	git add old.txt z.txt
	git commit --quiet -m old
	git mv old.txt new.txt
	sed -i '2s/.*/two/' new.txt
	echo c >>z.txt
	echo x >>a.txt
	# Two new files, so that a rename limit of 1 is exceeded.
	echo n >n1.txt
	echo n >n2.txt
	new_code --base HEAD
	expected=$json
	[ "$expected" = '{"a.txt":[[2,2]],"n1.txt":[[1,1]],"n2.txt":[[1,1]],"new.txt":[[2,2]],"z.txt":[[3,3]]}' ]
	printf '%s\n' z.txt a.txt >"$T/order"
	git config diff.renameLimit 1
	git config diff.orderFile "$T/order"
	git config diff.algorithm patience
	git config diff.interHunkContext 10
	git config diff.noprefix true
	git config diff.mnemonicPrefix true
	git config diff.renames false
	git config core.quotePath true
	run --separate-stderr "$assay" new-code --base HEAD
	[ "$status" -eq 0 ]
	pretty=$(jq -S . <<<"$expected")
	[ "$output" = "$pretty" ]
}
