bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# agents-md: AGENTS.md and CLAUDE.md at the root, CLAUDE.md the single line @AGENTS.md or either file a symlink to
# the other, and a "Related repos" section in the file that holds the instructions. The same predicate reads the
# working tree or a commit's tree.

related='# repo

## Related repos

- Depends on: none.'

# agents <content>: AGENTS.md. claude <content>: CLAUDE.md, written as given (printf %s).
agents() { printf '%s' "$1" >AGENTS.md; }
claude() { printf '%s' "$1" >CLAUDE.md; }

# both_ways <status> [<line>...]: agents-md on the working tree exits <status> printing exactly the lines given; so
# does agents-md on a commit of that tree, run after the working tree is changed to the opposite answer.
both_ways() {
	local expected=$1
	shift
	expected_output=$(if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi)
	run --separate-stderr "$assay" builtin agents-md
	echo "working tree: $status: $output"
	[ "$status" -eq "$expected" ]
	[ "$output" = "$expected_output" ]
	git add -A
	git commit --quiet --allow-empty -m shape
	rm -rf AGENTS.md CLAUDE.md
	if [ "$expected" -ne 0 ]; then
		agents "$related"
		claude '@AGENTS.md'
	fi
	run --separate-stderr "$assay" builtin agents-md HEAD
	echo "HEAD: $status: $output"
	[ "$status" -eq "$expected" ]
	[ "$output" = "$expected_output" ]
}

no_related='AGENTS.md has no "Related repos" section: add one naming the repos this one depends on and the repos that depend on it, with what passes between them, or saying there are none'

@test "CLAUDE.md as the single line @AGENTS.md passes, with or without its newline" {
	local_repo
	agents "$related"
	claude $'@AGENTS.md\n'
	both_ways 0
	agents "$related"
	claude '@AGENTS.md'
	both_ways 0
}

@test "a symlink either way passes" {
	local_repo
	agents "$related"
	ln -s AGENTS.md CLAUDE.md
	both_ways 0
	rm -rf AGENTS.md CLAUDE.md
	claude "$related"
	ln -s ./CLAUDE.md AGENTS.md
	both_ways 0
}

@test "a missing CLAUDE.md fails" {
	local_repo
	agents "$related"
	both_ways 1 "CLAUDE.md is missing: make it the single line @AGENTS.md"
}

@test "a missing AGENTS.md fails, and so does a missing pair" {
	local_repo
	claude '@AGENTS.md'
	both_ways 1 "AGENTS.md is missing: it holds the repo's instructions for every agent"
	rm -rf AGENTS.md CLAUDE.md
	both_ways 1 "AGENTS.md is missing: it holds the repo's instructions for every agent" \
		"CLAUDE.md is missing: make it the single line @AGENTS.md"
}

@test "a CLAUDE.md that copies AGENTS.md fails, even an identical one" {
	local_repo
	agents "$related"
	claude "$related"
	both_ways 1 "CLAUDE.md copies AGENTS.md: a copy falls short, even an identical one; make CLAUDE.md the single line @AGENTS.md"
}

@test "a CLAUDE.md with other content fails, a blank line after @AGENTS.md included" {
	local_repo
	agents "$related"
	claude '# Instructions for Claude'
	msg="CLAUDE.md is neither the single line @AGENTS.md nor a symlink to AGENTS.md: move its instructions into AGENTS.md, then make it the single line @AGENTS.md"
	both_ways 1 "$msg"
	agents "$related"
	claude $'@AGENTS.md\n\n'
	both_ways 1 "$msg"
}

@test "an AGENTS.md without a Related repos section fails" {
	local_repo
	agents $'# repo\n\nRelated repos: none.\n'
	claude '@AGENTS.md'
	both_ways 1 "$no_related"
	# Through a symlink, the section is looked for in the file that holds the instructions.
	rm -rf AGENTS.md CLAUDE.md
	claude $'# repo\n'
	ln -s CLAUDE.md AGENTS.md
	both_ways 1 "${no_related/AGENTS.md has/CLAUDE.md has}"
}

@test "the Related repos heading may have any level and case" {
	local_repo
	agents $'# repo\n\n### related REPOS ###\n\nNone.\n'
	claude '@AGENTS.md'
	both_ways 0
}

@test "symlinks to each other, or to another file, fail" {
	local_repo
	ln -s CLAUDE.md AGENTS.md
	ln -s AGENTS.md CLAUDE.md
	both_ways 1 "AGENTS.md and CLAUDE.md are symlinks to each other: AGENTS.md holds the instructions, and CLAUDE.md is the single line @AGENTS.md"
	rm -rf AGENTS.md CLAUDE.md
	mkdir docs
	printf '%s' "$related" >docs/agents.md
	ln -s docs/agents.md AGENTS.md
	claude '@AGENTS.md'
	both_ways 1 "AGENTS.md is a symlink to docs/agents.md: it holds the instructions itself, or is a symlink to CLAUDE.md"
	rm -rf AGENTS.md CLAUDE.md
	agents "$related"
	ln -s docs/agents.md CLAUDE.md
	both_ways 1 "CLAUDE.md is a symlink to docs/agents.md: make it the single line @AGENTS.md, or a symlink to AGENTS.md"
}

@test "a directory in place of either file fails" {
	local_repo
	agents "$related"
	mkdir CLAUDE.md
	touch CLAUDE.md/x
	both_ways 1 "CLAUDE.md is not a file: make it the single line @AGENTS.md"
}

@test "agents-md runs from a subdirectory, and on any commit-ish; something else is exit 2" {
	local_repo
	agents "$related"
	claude '@AGENTS.md'
	git add -A
	git commit --quiet -m shape
	git tag shaped
	rm CLAUDE.md
	mkdir sub
	cd sub
	run --separate-stderr "$assay" builtin agents-md shaped
	[ "$status" -eq 0 ]
	run --separate-stderr "$assay" builtin agents-md HEAD~1
	[ "$status" -eq 1 ]
	run --separate-stderr "$assay" builtin agents-md
	[ "$status" -eq 1 ]
	[ "$output" = "CLAUDE.md is missing: make it the single line @AGENTS.md" ]
	run --separate-stderr "$assay" builtin agents-md nope
	[ "$status" -eq 2 ]
	[ "$stderr" = "assay: agents-md: 'nope' is not a commit" ]
}

@test "a Related repos heading inside a fenced code block does not count; a CRLF @AGENTS.md line passes" {
	local_repo
	agents $'# repo\n\n```md\n## Related repos\n```\n'
	claude '@AGENTS.md'
	both_ways 1 "$no_related"
	agents "$related"
	claude $'@AGENTS.md\r\n'
	both_ways 0
}
