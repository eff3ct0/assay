---
name: assay-property
description: Chooses between an example test, a property-based test, a TLA+ model and a Lean proof, and keeps it next to the code where assay checks it. Use when writing or changing code whose correctness is a rule over all inputs (parsers, serializers, money and other arithmetic, data transformations, state machines), code whose correctness depends on the order in which processes, jobs or machines that share state act, or when a bug escaped the example tests.
---

# Properties: tests, models and proofs

A **property** is a statement that holds for every input or every behaviour, not for one example. A property-based
test tries it on generated inputs and shrinks a failure to a minimal **counterexample**; TLC checks it on every state of
a bounded TLA+ **model**; Lean proves it.

## Procedure

1. **Climb** [the ladder](#the-ladder) to the first step that answers the question.
2. **Write** the property, model or proof: [A good property](#a-good-property), [TLA+ models](#tla-models),
   [Lean proofs](#lean-proofs).
3. **Wire** the seed, with a repo's first property: [Under assay check](#under-assay-check).
4. **Explore** before the commit: [Exploration](#exploration).
5. **Keep** every counterexample: [Counterexamples](#counterexamples).
6. **Link** a model or proof to the code it abstracts: [Linking to the code](#linking-to-the-code).

Done when `assay check` passes with the property in it, exploration ran on every property you wrote or changed, each
counterexample it found is an explicit example committed with its fix, and every file a model or proof abstracts
names it.

## The ladder

Climbing only to the first step that answers the question:

1. an example test, the default;
2. a property-based test: a property holds for every input and can be stated without restating the implementation,
   over a large or structured input space; not when the only property is "returns what the code computes";
3. a stateful property-based test: one program with an API the test can drive, commands against a model, with a
   scheduler where the library has one (fast-check `fc.commands` with `modelRun` or `scheduledModelRun`,
   `proptest-state-machine`, Hypothesis `RuleBasedStateMachine`, ScalaCheck `Commands` with its parallel `property`);
4. a TLA+ model: correctness depends on the interleaving of actors that are separate systems (processes, jobs,
   machines sharing a git ref, a database, a queue), on retries or crashes mid-step, or the design is not code yet; it
   pays off before writing a protocol, or after an incident caused by a race;
5. a Lean proof: a property must hold for unbounded inputs, a failure is costly, and the core is small and pure; the
   proof covers the algorithm, and a property-based test ties the code to the same specification.

## A good property

**Forms**: round-trip (`decode (encode x) == x`), invariant, idempotence, oracle (a simple, slow version, or the old
implementation during a refactor), metamorphic relation (adding a filter never grows the result), stateful model
(commands against a model).

**Rules**:

- It does not restate the implementation: it states what must hold, however the code computes it.
- Generators are built from the library's combinators over the domain's types, not from filters, so that shrinking
  works, and they reach the edges (empty, boundaries, Unicode).
- One property per test, named by the test.
- Every counterexample found stays in the repo as an explicit example, in the same commit as the fix.
- It takes its seed and its number of cases from the run. A test's own seed escapes the fixed seed
  (`@settings(derandomize=False)`, fast-check's `seed`; munit-scalacheck's `.useSeed` draws one value every time), and
  a test's own number of cases (`max_examples`, `numRuns`) wins over exploration's. A slow munit-scalacheck property
  sets its count per suite (`override def scalaCheckTestParameters`), which keeps the seed.
- In munit-scalacheck, a property's body is a `Prop`: `.check(...)` returns `Unit`, printing a failure while the test
  passes.

## Under assay check

Property-based tests are ordinary tests in the repo's suite, run by its test check and counted in its coverage of new
code; they get no check of their own. Every run assay makes uses the fixed seed `ASSAY_SEED` (`assay.seed` in the
repo's `devenv.nix`, exported in its devenv), so the same tree gives the same result; changing it in a commit is how a
repo deliberately explores new inputs.

| Library          | Every run's seed                                  | With a repo's first property       |
| ---------------- | ------------------------------------------------- | ---------------------------------- |
| proptest         | `PROPTEST_RNG_SEED=$ASSAY_SEED` in the test check | add proptest 1.7.0 or later (dev)  |
| Hypothesis       | `--hypothesis-profile=ci` in the test check       | none: Python's preset holds it     |
| fast-check       | `fc.configureGlobal` in `vitest.setup.ts`         | none: TypeScript's preset holds it |
| munit-scalacheck | a base trait every property suite extends         | write the trait below              |

- proptest before 1.7.0 ignores `PROPTEST_RNG_SEED`.
- Hypothesis's `ci` profile is derandomized, with no database and no deadline: its inputs follow from each test, so
  `ASSAY_SEED` does not change them. Python's preset adds `hypothesis` and registers the `explore` profile in
  `conftest.py`.
- fast-check's `vitest.setup.ts`, named in `vitest.config.ts`'s `setupFiles`, sets `seed` from `ASSAY_SEED` and
  `numRuns` from `ASSAY_CASES`, each when it is set. TypeScript's preset adds `fast-check` and both files.
- Where the repo lacks a row's wiring (its test check is its own, or its preset predates it), the property comes with
  it: the variable or flag in the test check's command, the file where the library reads it.

munit-scalacheck's base trait:

```scala
import munit.ScalaCheckSuite
import org.scalacheck.Test.Parameters
import org.scalacheck.rng.Seed

// The seed and the number of cases of every property suite: assay's ASSAY_SEED and ASSAY_CASES, when set.
trait PropertySuite extends ScalaCheckSuite {
  override def scalaCheckInitialSeed: String =
    sys.env.get("ASSAY_SEED") match {
      case Some(s) => Seed(s.toLong).toBase64
      case None    => super.scalaCheckInitialSeed
    }
  override def scalaCheckTestParameters: Parameters =
    sys.env.get("ASSAY_CASES") match {
      case Some(n) => super.scalaCheckTestParameters.withMinSuccessfulTests(n.toInt)
      case None    => super.scalaCheckTestParameters
    }
}
```

## Exploration

Outside `assay check`, before the commit, whenever you write or change a property: the library's random default with
many more cases, from the repo's devenv. The devenv exports `ASSAY_SEED`, so the libraries that read it explore with it
unset.

| Library          | Exploration                                                   |
| ---------------- | ------------------------------------------------------------- |
| proptest         | `PROPTEST_CASES=10000` and no `PROPTEST_RNG_SEED`             |
| Hypothesis       | `--hypothesis-profile=explore`, with `ASSAY_CASES=10000`      |
| fast-check       | `env -u ASSAY_SEED ASSAY_CASES=10000` before the test command |
| munit-scalacheck | `env -u ASSAY_SEED ASSAY_CASES=10000` before the test command |

Raise the count while a run takes a few minutes or less. No scheduled run explores later: this one is the only one.

## Counterexamples

Kept in the form the library replays first, in the same commit as the fix:

| Library          | Kept as                                                                          |
| ---------------- | -------------------------------------------------------------------------------- |
| proptest         | `proptest-regressions/`, committed                                               |
| Hypothesis       | `@example(...)` on the test; `.hypothesis/` stays ignored                        |
| fast-check       | the `examples` parameter of `fc.assert`                                          |
| munit-scalacheck | a test with the fixed input: a seed stops reproducing once the generators change |

## TLA+ models

- **Layout**: `tla/<Name>.tla` with `tla/<Name>.cfg`, at the repo root. A second configuration of a spec is an
  `MC<Name>` module that extends it, `tla/MC<Name>.tla` with `tla/MC<Name>.cfg`.
- **Before a model is committed**, write a throwaway model in a scratch directory and run it there with
  `nix shell nixpkgs#tlaplus18 -c tlc -config <Name>.cfg <Name>.tla`.
- **Budget**: each configuration finishes in under a minute. Shrink the constants rather than grow the budget.
- **A spec that terminates** ends in a step that stutters (`Done == ... /\ UNCHANGED vars` in `Next`), or TLC reports
  its end as a deadlock.
- **The `tla` check**: off by default; turning it on is the repo's choice, in its `devenv.nix`
  (`assay.checks.tla.enable = true;`), which brings TLC (`tlaplus18`) into its devenv. Then `assay check tla`, and
  every full run, checks each `tla/<Name>.cfg` against `tla/<Name>.tla`; a violation fails it, and its log holds the
  trace, the same on every run.

## Lean proofs

- Through devenv's `languages.lean4.enable` (nixpkgs' `lean4`, Lake included), with the Lake package in `lean/`.
- Without elan, `lean-toolchain` is ignored: the version is the devenv's.
- Mathlib is decided when a case needs it: it needs elan, a matching toolchain and a cache downloaded over the network.
- assay gains a `lean` check (`lake build --wfail`, so that a `sorry` fails) with the first Lean case. A proof you
  write before it exists is that case: tell the user, and run `lake build --wfail` in `lean/` before each commit.

## Linking to the code

A model's or proof's header lists the files it abstracts, and each of those files carries a comment naming the model
or proof. Whoever changes a pointed-at file rereads the model and checks it again (`assay check tla`). No check
catches a drift: the comment is the link.

## Not used

Quint (its `verify` downloads Apalache), Apalache (not in nixpkgs), trace validation and model-based test generation.
