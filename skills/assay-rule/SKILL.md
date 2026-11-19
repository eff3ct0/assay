---
name: assay-rule
description: Turns a correction into a rule, a check that fails on the corrected case, instead of a line of prose. Use when the user tells you that something you did must not be done that way again, about a repo's code, the commands you run or the files you edit, commits and pushes, or the machine's configuration.
---

# A correction becomes a rule

A **rule** is a check born from a correction: it fails on the corrected case, passes on its fix, and its message says
why and what to do instead.

- **Correction**: the user telling an agent that something it did must not be done that way again, a standing
  preference; steering a single step is not one. The agent turns every correction into a rule without asking, right
  away, before it goes on with its task, and says so in its report. When it cannot tell a correction from steering, it
  asks the user one question: whether this holds from now on.

## Procedure

1. **Classify** the correction: [Where each correction goes](#where-each-correction-goes). For a code rule, climb
   [the ladder](#the-ladder-for-code-rules) to the first step that holds it.
2. **Scaffold** the rule:
   - an ast-grep rule (step 5 of the ladder): from inside the repo, run
     `assay rule new <kebab-name> [--lang <lang>] [--from <file>:<line>[-<line>]]`, with `--from` naming the corrected
     code. It writes `sgconfig.yml` when the repo has none, `rules/<name>.yml` and `rule-tests/<name>-test.yml` (into
     the directories an existing `sgconfig.yml` names), and prints their paths. `--lang` defaults to the language
     ast-grep gives `--from`'s file, else to the repo's single enabled language. Exit 1: a rule of that name exists,
     so extend it or pick another name.
   - a native rule (steps 2 to 4): a line in its tool's configuration, written by hand.
   - a guard or `commit-msg` rule: an entry in the machine's rule list, written by hand: `name` (its stable id), `on`
     (`command`, `path` or `commit-msg`), `match` (an ast-grep rule for bash, a glob, or a regex), `message`, `note`,
     `who` (`agents` or `everyone`), and `deny` and `allow` examples, which the rule list's check builder feeds to the
     real entrypoints.
   - a test in the repo's own suite (step 6), an expectation in the machine's configuration checks, or prose: as their
     sections say.
3. **Write** the message and note: [The message](#the-message). In an ast-grep scaffold, replace every
   `<fill in: …>` placeholder; the comment above each field says what it holds. `assay check ast-grep` fails while any
   placeholder is left.
4. **Test** the rule: [Testing](#testing).
5. **Clean up** the existing occurrences: [Existing occurrences](#existing-occurrences).
6. **Commit**: [Commits](#commits).

Done when the rule fails on the corrected code, passes on its fix and its near miss, `assay check` passes on the whole
tree, and your report names the rule and where it lives. A guard or `commit-msg` rule is done when its pull request is
open and its check builder passes.

## Where each correction goes

| The correction is about                                      | It becomes                                                       |
| ------------------------------------------------------------ | ---------------------------------------------------------------- |
| the code of a repo                                           | a code rule in that repo                                         |
| what an agent does: the commands it runs, the files it edits | a guard rule in the machine's rule list (`programs.assay.rules`) |
| commits and pushes                                           | a `commit-msg` rule in the same list                             |
| the machine's own system configuration                       | an expectation in that configuration's own checks                |
| something no deterministic check can tell                    | prose, saying why no check holds it                              |

## The ladder for code rules

Climbing only to the first step that holds:

1. by construction (a type, a narrower API, a template);
2. a lint the linter already has (clippy `unwrap_used`, ESLint `no-explicit-any`, ruff `T201`...);
3. forbidding a named item through the linter's ban list, which resolves imports and aliases: clippy
   `disallowed-methods` / `-types` / `-macros` with `reason`, ruff `TID251` banned-api with `msg`, ESLint or oxlint
   `no-restricted-imports` with `message`;
4. a dependency between parts of the repo: the boundary tool (dependency-cruiser, import-linter, the crate graph plus
   cargo-deny `bans`, sbt `dependsOn`);
5. a shape of the code: an ast-grep rule, one format and one test harness for all six languages. Scala, Nix and bash
   have no light ban list, so their bans are ast-grep rules too. In Nix, anything about evaluated values is a flake
   check instead;
6. what ast-grep cannot parse (Markdown, the shape of the file tree): a test in the repo's own suite (a flake check in
   a Nix repo, bats in a bash repo). A correction about behaviour that holds for every input becomes a property-based
   test, through `assay-property`.

## The message

Severity always `error`; `message`, one line at the location, what is wrong and what to do instead; `note` with
**Why** (the root cause), **Fix** (the right change, concretely) and **Not a fix** (the known dodges: renaming,
aliasing, casting, moving the call elsewhere, suppressing), ending with the fixed closing line: if the rule is wrong
here, stop and tell the user; exceptions go in the rule's own file. English; no quote of the user; nothing that names a
machine; an optional `url` only to a document in the same repo. Native rules carry the same text in their tool's
message field (clippy `reason`, ruff `msg`, ESLint `message`, dependency-cruiser `comment`).

In an ast-grep rule, the closing line is the note's last line, as `assay rule new` writes it:

```yaml
note: |
  Why: …
  Fix: …
  Not a fix: …
  If the rule is wrong here, stop and tell the user; exceptions go in the rule's own file.
```

## Exceptions

Exceptions live in the rule (`ignores` globs, a `not:` clause), never inline. The `ast-grep` check fails on any
`ast-grep-ignore` outside the rule directories.

## Testing

Every ast-grep rule has at least one `invalid` case (the corrected code cut to the minimum) and at least one `valid`
case (its fix, plus a near miss: the same words in a string or comment, a similar call that is fine). A native rule
gets no test of its own: the body of the commit that adds it shows the check failing on the corrected code before the
fix and the tree passing after.

`assay check ast-grep` runs `ast-grep test --skip-snapshot-tests`, then `ast-grep scan`; a guard rule's examples run
through the rule list's check builder.

## Existing occurrences

Existing occurrences are cleaned in the same commit as the rule, so it lands green: the rule's `fix:` with
`ast-grep scan -U`, or the linter's `--fix`, where the rewrite is mechanical; by hand otherwise. What the agent cannot
verify in its session goes into the rule's `ignores`, under a comment marking those files as existing occurrences, and
the agent tells the user.

## Commits

A code rule is its own commit on the current branch (the rule, its tests and the cleanup), with the correction quoted
verbatim in the commit body, in the user's language; its message, note and comments stay in English. A guard or
`commit-msg` rule is its own branch `agent/rule-<name>` in the repository that holds the machine's configuration, with a
pull request the user merges and applies; the agent goes back to its task meanwhile.

## Where rules live

ast-grep's own layout (`sgconfig.yml`, `rules/<name>.yml`, `rule-tests/<name>-test.yml`); native rules in their tool's
configuration.

**Rule packs**: an opt-in pack of ast-grep rules in assay, which a repo turns on in its `devenv.nix`
(`assay.rulePacks = [ "<name>" ];`). Enabling a pack is adding rules, so the same cleanup of existing occurrences
applies. A rule moves into a pack when the correction says it holds for every repo of a language, or when a second repo
needs it; the first repo then drops its copy. A pack's rules take no exception from a repo: a repo whose existing
occurrences cannot all be cleaned up keeps its own copy of the rule, with those files in its `ignores`, and turns the
pack on once they are gone.

A rule is born in the repo where the correction happened, and moves to a pack as above. A native rule that holds for
every repo of a language joins that language's preset as a new version. In a repo of a shared organization, a rule is a
branch and pull request its members review, and binds only once merged.

## Prose

A new correction adds no prose unless no check can hold it; then it goes in the `AGENTS.md` that applies, saying why no
check holds it. Existing prose lines stay.
