# Task: `assay preset`, the `preset` check, and bash's preset

A working note for whoever continues this branch; it is removed once the last critic passes.

## The request, verbatim

> /mattpocock-skills:implement https://github.com/eff3ct0/assay/issues/5
>
> Toma tú cada decisión con tu recomendación, sin esperarme. Sigue ~/git/AGENTS.md: worktree de grove en una rama
> agent/, y el crítico te toca a ti, porque tú eres el autor de este cambio. Termina con un pull request que diga
> "Closes https://github.com/eff3ct0/assay/issues/5" y no lo mergees.

The issue links its spec: eff3ct0/nixos-config#58 (its resolution comment) and #55's comment refining adoption.

## Decisions

- Layout: `preset/<language>/<version>/`, each version a full snapshot of the files at the paths they take in the
  repo; the pinned version is the highest. `preset/README.md` says what a preset holds and how to raise a version.
- The CLI finds the presets through `assay_presets`, which the package sets on the line before the script (as
  `assay_tools`); run from a checkout, they are `preset/` beside the script, through symlinks.
- The module writes `languages` into the configuration (`bash` with `languages.shell.enable`, `nix` with
  `languages.nix.enable`); the CLI reads it, optional (absent means none).
- bash's preset applies when the repo tracks a shell script, as `shfmt -f` finds them (the spec's "first tracked
  shell script", taken literally after the review).
- `assay preset <language>...` takes the languages named (they need a preset, nothing else); with none, every enabled
  language whose preset applies.
- The record is raised for every language processed, conflicts and kept files included, so a resolved conflict is
  not merged again.
- The tool's other files (bash: `shellcheckrc` for `.shellcheckrc`) are a table in `assay.sh`; they share the preset
  file's format, so they are merged and shown like it.
- A record newer than the pinned preset, or naming a version assay does not hold, is exit 2. Unknown languages in the
  record are kept.
- Header line: `preset behind: <language> <recorded> → <pinned> (assay preset <language>)`, for every recorded
  language behind, enabled or not; an unreadable record is left to the `preset` check.
- Conflict markers a merge left are reported (exit 1) by every later run until they are resolved; shellcheck also
  fails on a `.shellcheckrc` that holds them. Without shfmt, `assay builtin preset` exits 127.
- assay's own repo: a cleanup commit makes its scripts pass the preset's optional shellcheck checks (a file-level
  `SC2310` suppression with its reason in `assay.sh`, whose predicates and git wrapper are conditions on purpose, two
  line-level ones in `nix/rules-check.sh`; every other finding fixed), then `assay preset bash` is run and committed.

## Steps

1. `assay.sh`: presets, `assay preset`, `assay builtin preset`, the header line, usage. (done)
2. Module: `languages` in the configuration; `preset` built-in check; package sets `assay_presets`. (done)
3. `preset/bash/1/.shellcheckrc`, `preset/README.md`. (done)
4. Tests: `test/preset.bats`, built-in lists and `test/defaults/*.json`, `nix/checks.nix`, the bash fixture in
   `test/devenv/defaults.bats` built with `assay preset bash`, a real-devenv test in `test/devenv/module.bats`. (done)
5. Docs: README, `preset/README.md`, `docs/adoption.md`, AGENTS.md. (done)
6. Cleanup of the optional checks' findings in every shell file (the `.bats` files of `test/` by three subagents,
   one set of files each); `assay preset bash` on assay itself. (done)
7. `devenv test`, `bats test/devenv`, `nix flake check`; commits. (done: `devenv test` passed, 206 tests, new code
   87% covered)
8. Review (`code-review` skill): fixes applied. Critic, then the pull request. (in progress)
