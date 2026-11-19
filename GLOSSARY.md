# assay

assay holds a repo's named checks and runs them the same way before a commit, in CI and in an agent's loop. These
are the words its specification uses.

## Checks

**Check**:
Deterministic, passes or fails, and stops the agent inside its loop (pre-commit, `assay check`, CI). Lint, types,
tests, dependency rules, coverage of new code.
_Avoid_: "coverage does not drop" (the check is coverage of new code)

**Fast check**:
A check that only reads source files, and so runs before every commit.

**Full run**:
Every check of a repo; what CI, the agent and the critic run.

**Skipped check**:
A check that did not run because the file it requires is missing from the tree; it counts as passing, and
`assay check` lists it.
_Avoid_: marker (for the required file; the agent marker is another thing)

**Loosening**:
An override that makes one of assay's default checks less strict than the default.

**Built-in check**:
One of assay's default checks that every repo importing its devenv module runs, whatever the repo's languages.

**Base**:
The commit a change is measured against; the change is everything between it and the working tree.

**New code**:
The lines a change adds or modifies, compared with its base.

**Preset**:
The configuration files and development dependencies a language's default checks need in a repo, held by assay and
written into the repo, where they become the repo's own.
_Avoid_: baseline (in linters, the accepted existing findings)

**Preset version**:
The number of a language's preset, raised when it changes; a repo records the version it last took.

## Analyzer and findings

**Analyzer**:
A tool the agent consults about its own change while it works. It returns findings (smells, duplication, complexity,
security); findings on new code can be turned into a check.

**Finding**:
What the analyzer returns about the code: a smell, duplication, complexity or a security issue, at a place.

**New finding**:
A finding the change introduces: on new code, or with no counterpart at the base.

**Suppression**:
A comment or attribute in the code that silences a finding at that place.

## Verification

**Verification**:
Produces evidence that behaviour is right: running the app, property-based tests, TLA+ models or Lean proofs.

**Property**:
A statement about code that must hold for every input or every behaviour, not for one example.

**Property-based test**:
A test that checks a property on generated inputs and shrinks a failure to a minimal counterexample.

**Counterexample**:
An input or a sequence of steps for which a property fails.

**Model**:
A TLA+ specification of how a system behaves, which TLC checks exhaustively within bounds.

**Proof**:
A Lean theorem about an algorithm, checked by Lean's compiler.

## Rules

**Correction**:
The user telling an agent that something it did must not be done that way again; steering a single step is not one.

**Rule**:
A check born from a correction: it fails on the corrected case, passes on its fix, and its message says why and what
to do instead.

**Code rule**:
A rule about a repo's contents, kept in that repo.

**Guard rule**:
A rule about what an agent does, kept in the machine's rule list.

**Agent marker**:
What tells assay's hooks that an agent, not a person, is acting.

## Metrics

**Metric**:
Measured and charted over time; it stops nobody. A metric stops an agent only once it is turned into a check.

**Snapshot**:
The code metrics of a repo's default branch tip, measured once a night when it moved.

**Landed change**:
A first-parent commit on a repo's default branch, made by a person rather than a bot.

**Hit**:
One time a check stopped someone (a guard denial, a git hook rejection, a failing check in `assay check`, a `Stop`
hook block), recorded when it happens.

## Dependencies

**Advisory**:
A published record that a range of a package's versions is vulnerable, naming the versions that fix it.

**Untouched dependency**:
A locked dependency version that a change neither adds nor changes.

**Security update**:
A pull request that moves a locked dependency to a version its advisories name as fixed.

## Adoption

**Adoption**:
The change that wires an existing repo into assay, landing green.

**Adopted repo**:
A repo whose default branch's devenv imports assay's module.
_Avoid_: mandatory (it names the target, not the state reached)
