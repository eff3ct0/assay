# Task: issue #14, the `assay-property` skill and the `tla` check

Removed once the last critic passes.

## The request, verbatim

> /mattpocock-skills:implement https://github.com/eff3ct0/assay/issues/14
>
> Toma tú cada decisión con tu recomendación, sin esperarme. Sigue ~/git/AGENTS.md: worktree de grove en una rama
> agent/, y el crítico te toca a ti, porque tú eres el autor de este cambio. Termina con un pull request que diga
> "Closes https://github.com/eff3ct0/assay/issues/14" y no lo mergees.

A note that came during the work, verbatim:

> Nota del orquestador, por un incidente de hoy (un crítico borró /run/user/1000): cuando lances un crítico o
> cualquier subagente que ejecute scripts, pon en su brief estos límites: scripts con set -euo pipefail; toda ruta que
> se borre o cambie de permisos usa ${VAR:?} y está dentro de un directorio creado con mktemp -d; nada de rm ni chmod
> -R sobre una ruta calculada sin comprobar antes que empieza por ese directorio. Tú también, y sigue con lo tuyo.

The issue (`gh issue view 14 -R eff3ct0/assay`) and its specs (eff3ct0/nixos-config#57, #58, #45) are the source.

## Decisions

- The skill is `skills/assay-property/SKILL.md`; the home-manager module already installs every directory of
  `skills/`, so the change there is its check (`nix/checks.nix` compares every skill, not only `assay-rule`).
- The `tla` check lives in `devenv/defaults.nix` beside the built-in checks, `enable = false`, full run,
  `requires = "tla/*.cfg"`, `exec = "assay builtin tla"`: it is assay's own code, like gitleaks' wrapper, with a test
  file of its own (`test/tla.bats`, real TLC) and exit 127 when `tlc` is missing.
- An off-by-default check's tools join the devenv only once the repo turns it on (generic, in `devenv/module.nix`), so
  `tlaplus18` (Java 21) reaches only the repos that turn `tla` on. A check on by default keeps its tools when turned
  off, as before.
- `assay check --list` lists every check, marking off ones `(off)` (`tla (off)`, `name (fast, off)`): the issue asks
  `--list` to show `tla` as off, and it listed only enabled checks.
- `assay builtin tla`: empties `<git-dir>/assay/tla`, then for each `tla/*.cfg` git sees (name order) runs
  `tlc -workers 1 -fp 0 -noGenerateSpecTE -metadir <git-dir>/assay/tla -config tla/<Name>.cfg tla/<Name>.tla` from the
  root with `JDK_JAVA_OPTIONS=-Djava.io.tmpdir=<git-dir>/assay/tla/tmp`; every configuration runs; a `.cfg` without its
  `.tla` fails with a plain message; any non-zero exit fails. TLC leaves a timestamped states directory in the metadir
  on a violation, hence the emptying.
- Tests need `tlaplus18` on the PATH: `nix/test-tools.nix` (dev shell, sandbox) and assay's own `devenv.nix`.
- The issue's "To verify" was run with each library (Hypothesis 6.151.10, fast-check 4.10.3 under Vitest 5.1.1,
  munit-scalacheck 1.3.1, proptest 1.12.0 and 1.6.0/1.7.0): a test's own seed escapes the fixed one
  (`@settings(derandomize=False)`, fast-check's `seed`; munit-scalacheck's `.useSeed` repeats one value); a test's own
  case count beats the exploration knob except proptest's `PROPTEST_CASES`; munit-scalacheck's `.check(...)` passes
  a false property; under Hypothesis's `ci` profile (derandomized) `ASSAY_SEED` changes nothing. The skill says so,
  and the PR reports the Hypothesis point against the issue's text (it bears on Python's preset, #7).
- Exploration unsets `ASSAY_SEED` for fast-check and munit-scalacheck: the devenv always exports it.

- The skill says what holds today: the TypeScript and Python presets (issues #7, #8) do not exist yet, so a repo
  without them brings the wiring with its first property.
- After the code review (Standards and Spec): "built-in" now covers opt-in checks (GLOSSARY), long lines reflowed,
  `tla_fp` became a commented local, the test helpers deduplicated, the home check derives the skill names from
  `skills/`, and the skill gained the `lean` check's "full run, on with the language". Left as they are: a shared
  `need_tool` helper and the copied `ln -s` loop of the 127 tests (they touch code outside this change), and the
  Hypothesis point (the skill states the verified fact; the PR raises it for #7).

## Remaining steps

1. Done: `--list`, the `tla` check and `assay builtin tla`, the skill and `assay-rule`'s step, the home check, the
   devenv test, the docs, the code review's fixes. `nix flake check` passed before the review's fixes.
2. `devenv test` in full; the critic; the PR with "Closes https://github.com/eff3ct0/assay/issues/14".
