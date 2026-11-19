# Presets

A language's **preset** is the configuration files and development dependencies its default checks need in a repo.
assay holds every version of each language's preset here; `assay preset` writes the pinned one into a repo, which owns
the files from then on, and merges later versions in ([README.md](../README.md#assay-preset)).

## Layout

- `preset/<language>/<version>/` holds every file of that version, at the path it takes in the repo, from the repo
  root. The language is assay's name for it, the one `.assay-preset.json` records (`bash`, enabled in devenv with
  `languages.shell.enable`).
- The highest version is the pinned one: what a repo gets from the version of assay its `devenv.lock` pins.
- Every version stays, so that a repo at any of them merges the pinned one in three ways, with its recorded version
  as the base, without network.
- Nix has no preset: its tools need no configuration.

## What a preset holds

A preset holds what the tool checks (which rules, how strict, licenses, boundaries), while a default check's command
holds what makes the tool a check and assay's policy.

How strict: everything a tool offers that finds defects, and nothing that only enforces a style choice the formatter
or another check already makes. Where a language's strictness can only live in its project file, the preset keeps the
tool's defaults.

## When a preset applies, and where it writes

- `assay preset` with no language takes every language the repo's devenv enables whose preset applies; the `preset`
  check fails while such a language is missing from the record.
- bash's applies once the repo tracks a shell script, as `shfmt -f` finds them (by extension or shebang). Its files
  go at the repo root, since shellcheck reads `.shellcheckrc` from each script's directory upward.
- A tool may read another file in place of a preset file: shellcheck reads `shellcheckrc` where a directory has no
  `.shellcheckrc`. When the repo has such a file, it is the tool's: the preset writes none of its own beside it, which
  would silently replace it, and merges into it and shows it instead. `preset_others` in `assay.sh` lists these files;
  each must have the preset file's format.

## Raising a version

1. Copy `preset/<language>/<N>/` to `<N + 1>/` and make the change there. Never edit a version that has shipped:
   repos recorded at it merge from it.
2. A file the new version drops stays in the repos that have it, which own it.
3. The fixtures of `test/devenv/defaults.bats` are built from the pinned version by `assay preset`, so assay's own
   tests prove what repos receive; adjust them with the change.
4. Repos take it with `assay preset`, which the weekly update runs. Until then, `assay check`'s header lists the
   language as behind; a version behind fails nothing.

## bash

Version 1:

- `.shellcheckrc`: `enable=check-extra-masked-returns,check-set-e-suppressed,check-unassigned-uppercase`, the
  optional checks that find defects rather than set style.
- No `.editorconfig`: shfmt keeps its defaults (tabs).

## Scala

Version 1 applies with `languages.scala.enable` and a root `build.sbt`. The project keeps its own sbt pin and test
framework. `project/plugins.sbt` pins the four sbt 2 plugins; `lint.sbt` enables SemanticDB and WartRemover's unsafe
set. DisableSyntax also rejects `finalize` overrides and `final val` definitions (inlined constants can leave
downstream bytecode stale). It does not repeat the compiler's unused checks.

`assay preset scala` fills `.scalafmt.conf` from `scalafmt --version`. A merge renders the old and new templates with
the same CLI version, so local edits stay local. When only the CLI changes, update the project's `version` as the
fast check directs. A mismatch stops at scalafmt's version check, before it can invoke the downloading runner.

`test/devenv/scala.bats` prints timings. On the Scala 3.10.1 fixture (sbt 2.0.12, scalafmt 3.11.5, warm dependencies),
scalafmt took 0.53 s, within the fast set's 5 s budget. Compilation took 4.00 s, scalafix 2.99 s, and tests with
coverage 5.78 s (5.06 s on repeat). The coverage run disables sbt's task cache: after `clean`, restoring instrumented
classes alone cannot restore their scoverage metadata. It runs `testFull` and maps each Cobertura class through the
report's real source roots before diff-cover measures it.
