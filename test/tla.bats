# shellcheck disable=SC2016 # the models' TLA+ text is literal
bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

# The tla check (`assay builtin tla`), with the real TLC (tlaplus18), over models in throwaway repos.

# counter <atomic|racy>: tla/Counter.tla and tla/Counter.cfg, a model of processes that each add one to a shared
# counter, either in one atomic step or as a read followed by a write, which loses an update when two interleave.
# NoLostUpdate holds for the atomic one only.
counter() {
	mkdir -p tla
	{
		printf '%s\n' '---- MODULE Counter ----' 'EXTENDS Naturals, FiniteSets' 'CONSTANTS Procs' \
			'VARIABLES count, pc, tmp' 'vars == <<count, pc, tmp>>' \
			'Init == count = 0 /\ pc = [p \in Procs |-> "read"] /\ tmp = [p \in Procs |-> 0]'
		if [ "$1" = atomic ]; then
			printf '%s\n' 'Read(p) == pc[p] = "read" /\ count'"'"' = count + 1 /\ pc'"'"' = [pc EXCEPT ![p] = "done"]' \
				'           /\ UNCHANGED tmp' \
				'Write(p) == FALSE'
		else
			printf '%s\n' 'Read(p) == pc[p] = "read" /\ tmp'"'"' = [tmp EXCEPT ![p] = count]' \
				'           /\ pc'"'"' = [pc EXCEPT ![p] = "write"] /\ UNCHANGED count' \
				'Write(p) == pc[p] = "write" /\ count'"'"' = tmp[p] + 1 /\ pc'"'"' = [pc EXCEPT ![p] = "done"]' \
				'            /\ UNCHANGED tmp'
		fi
		printf '%s\n' 'Done == (\A p \in Procs : pc[p] = "done") /\ UNCHANGED vars' \
			'Next == (\E p \in Procs : Read(p) \/ Write(p)) \/ Done' \
			'Spec == Init /\ [][Next]_vars' \
			'TypeOK == count \in 0..Cardinality(Procs)' \
			'NoLostUpdate == (\A p \in Procs : pc[p] = "done") => count = Cardinality(Procs)' \
			'===='
	} >tla/Counter.tla
	printf '%s\n' 'CONSTANTS' '  Procs = {p1, p2}' 'SPECIFICATION Spec' 'INVARIANT TypeOK' 'INVARIANT NoLostUpdate' \
		>tla/Counter.cfg
}

# trace <log>: a violation's trace in TLC's output, from its error to the count of states: what the check keeps the
# same from run to run (TLC's header and timestamps vary).
trace() { sed -n '/^Error: /,/ states generated, /p' "$1"; }

# tlc_lines: the configuration and spec of each TLC run the output shows, one per line.
tlc_lines() { sed -n 's/^\$ tlc .* -config //p' <<<"$output"; }

@test "a correct model passes, fast, and leaves the tree as it was: no states/, no trace module" {
	shaped_repo
	tla_on
	counter atomic
	git add tla
	git commit --quiet -m model
	SECONDS=0
	run --separate-stderr "$assay" check tla
	echo "$output"
	[ "$status" -eq 0 ]
	[ "$SECONDS" -lt 60 ]
	[[ ${lines[1]} == "ok   tla "* ]]
	git_dir=$(git rev-parse --absolute-git-dir)
	grep -qF 'Model checking completed. No error has been found.' "$git_dir/assay/tla.log"
	grep -qF -- "\$ tlc -workers 1 -fp 0 -noGenerateSpecTE -metadir $git_dir/assay/tla -config tla/Counter.cfg" \
		"$git_dir/assay/tla.log"
	prints '' git status --porcelain --ignored
}

@test "a broken invariant fails the check, its log holds the trace, and two runs give the same trace" {
	shaped_repo
	tla_on
	counter racy
	git add tla
	git commit --quiet -m model
	git_dir=$(git rev-parse --absolute-git-dir)
	run --separate-stderr "$assay" check tla
	echo "$output"
	[ "$status" -eq 1 ]
	[[ ${lines[1]} == "FAIL tla "*" (exit 1)" ]]
	[[ $output == *"Error: Invariant NoLostUpdate is violated."* ]]
	[[ $output == *"tla/Counter.cfg: TLC exit 12"* ]]
	grep -qF 'Error: Invariant NoLostUpdate is violated.' "$git_dir/assay/tla.log"
	grep -qF 'State 5: <Write ' "$git_dir/assay/tla.log"
	trace "$git_dir/assay/tla.log" >"$T/first"
	run --separate-stderr "$assay" check tla
	[ "$status" -eq 1 ]
	trace "$git_dir/assay/tla.log" >"$T/second"
	[ -s "$T/first" ]
	diff "$T/first" "$T/second"
	prints '' git status --porcelain --ignored
	# TLC leaves its states in the git directory after a violation; the next run starts from an empty directory.
	states=$(find "$git_dir/assay/tla" -name '*.st')
	[ -n "$states" ]
}

@test "every configuration runs in name order: MC<Name> extends its spec; a deadlock, a parse error, a configuration error and a .cfg with no .tla each fail" {
	local_repo
	counter atomic
	printf '%s\n' '---- MODULE MCCounter ----' 'EXTENDS Counter' 'MCProcs == {"a", "b", "c"}' '====' >tla/MCCounter.tla
	printf '%s\n' 'CONSTANTS' '  Procs <- MCProcs' 'SPECIFICATION Spec' 'INVARIANT NoLostUpdate' >tla/MCCounter.cfg
	# No Done step: the processes stop, which TLC reports as a deadlock.
	sed -e 's/MODULE Counter/MODULE Stuck/' -e 's/ \\\/ Done$//' tla/Counter.tla >tla/Stuck.tla
	sed 's/^INVARIANT NoLostUpdate$//' tla/Counter.cfg >tla/Stuck.cfg
	printf '%s\n' '---- MODULE Broken ----' 'VARIABLE x' 'Init == x =' 'Next == x'"'"' = x' '====' >tla/Broken.tla
	printf '%s\n' 'INIT Init' 'NEXT Next' >tla/Broken.cfg
	printf '%s\n' 'SPECIFICATION Spec' >tla/Unset.cfg
	sed 's/MODULE Counter/MODULE Unset/' tla/Counter.tla >tla/Unset.tla
	printf '%s\n' 'INIT Init' >tla/Orphan.cfg
	run --separate-stderr "$assay" builtin tla
	echo "$output"
	[ "$status" -eq 1 ]
	prints "$(printf '%s\n' 'tla/Broken.cfg tla/Broken.tla' 'tla/Counter.cfg tla/Counter.tla' \
		'tla/MCCounter.cfg tla/MCCounter.tla' 'tla/Stuck.cfg tla/Stuck.tla' 'tla/Unset.cfg tla/Unset.tla')" tlc_lines
	[[ $output == *"Error: Deadlock reached."* ]]
	[[ $output == *"The constant parameter Procs is not assigned a value by the configuration file."* ]]
	prints "$(printf '%s\n' 'tla/Broken.cfg: TLC exit 150' 'tla/Orphan.cfg: no tla/Orphan.tla beside it' \
		'tla/Stuck.cfg: TLC exit 11' 'tla/Unset.cfg: TLC exit 151' '4 of 6 TLA+ configurations failed')" \
		tail -n 5 <<<"$output"
	prints '?? tla/' git status --porcelain --ignored
}

@test "the configurations are the tla/*.cfg git sees: an ignored one, and one in a subdirectory, are not run" {
	local_repo
	counter racy
	mkdir tla/old
	mv tla/Counter.tla tla/Counter.cfg tla/old/
	counter atomic
	sed 's/MODULE Counter/MODULE Scratch/' tla/old/Counter.tla >tla/Scratch.tla
	cp tla/old/Counter.cfg tla/Scratch.cfg
	echo 'tla/Scratch.*' >.gitignore
	run --separate-stderr "$assay" builtin tla
	echo "$output"
	[ "$status" -eq 0 ]
	prints 'tla/Counter.cfg tla/Counter.tla' tlc_lines
}

@test "with no tla/*.cfg, assay builtin tla passes and says so; it takes no argument" {
	local_repo
	run --separate-stderr "$assay" builtin tla
	[ "$status" -eq 0 ]
	output_is "no tla/*.cfg to check"
	run --separate-stderr "$assay" builtin tla extra
	[ "$status" -eq 2 ]
	[ "${stderr_lines[0]}" = "assay: tla takes no argument" ]
}

@test "without tlc on the PATH the check exits 127" {
	local_repo
	counter atomic
	check tla "\"$assay\" builtin tla"
	# Only the tools assay check itself needs.
	mkdir "$T/bin"
	for t in bash git jq head tail wc mkdir rm; do
		target=$(command -v "$t")
		ln -s "$target" "$T/bin/$t"
	done
	PATH=$T/bin run "$assay" check
	[ "$status" -eq 1 ]
	[[ ${lines[1]} == "FAIL tla "*"(exit 127: tool not found)" ]]
	PATH=$T/bin run -127 --separate-stderr "$assay" builtin tla
	[ "$status" -eq 127 ]
	[ "$stderr" = "assay: cannot find tlc on the PATH" ]
}
