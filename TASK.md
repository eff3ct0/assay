# Task: `assay findings` and the `findings` check over qlty

Removed once the last critic passes.

## The request, verbatim

```
/mattpocock-skills:implement https://github.com/eff3ct0/assay/issues/11
```

The issue's body is the specification (`gh issue view 11 -R eff3ct0/assay`), with the specifications it links.

## Facts verified while implementing (qlty 0.671.0, radarlint 2.0.0)

- qlty runs offline: `qlty --version`, `qlty smells` and `qlty check` with plugins defined in `.qlty/qlty.toml` and no
  `[[source]]` need no network. The release's `.sha256` is the tarball's sha256.
- `--upstream <commit hash>` works for `check` and `smells`; qlty diffs the merge base of that commit and HEAD against
  the working tree, untracked files included (not excluded ones: `.qlty/` in `.git/info/exclude` stays out).
- `qlty check` filters findings to those whose line range meets an added line. `--no-fail` makes it exit 0 with
  findings; 3 is a plugin error ("Lint error"), 99 any other error. With no plugin enabled it prints an empty run.
- `qlty smells` needs a git repository (exit 99 "This must be run within a Git repository"); a copy of the base with
  `git init` and no commit is enough. `qlty smells <path>...` gives the structure smells of those files and the clones
  that involve them, matched across all files. A path that does not exist is exit 99.
- `qlty smells --upstream` reports, for the changed files only, all their structure smells and their clone
  locations (each location an issue, `relatedLocations` the others, `properties.structural_hash` the clone's hash).
- Smell messages: `Function with high complexity (count = N): <name>` (also `partialFingerprints["function.name"]`),
  `Function with many parameters (count = N): <name>`, `Function with many returns (count = N): <name>`,
  `High total complexity (count = N)`, `Deeply nested control flow (level = N)`, `Complex binary expression`,
  `Found N lines of identical|similar code in K locations (mass = M)`. SARIF regions carry `sourceLanguage`
  (`python`, `rust`, `scala`, `typescript`, `tsx`, ...). Rule ids: `qlty:function-complexity` and so on; a plugin's:
  `<plugin>:<rule>`, e.g. `radarlint-python:python:S1481`. URIs are percent-encoded (space, `:`, `%`, non-ASCII...).
- `[language.<x>] enabled = false` does not stop smells; assay keeps the results whose `sourceLanguage` is
  typescript, tsx, rust, python or scala.
- radarlint is a 181 MB tarball (`radarlint.jar` plus `plugins/sonar-*.jar`) at
  `https://radarlint-releases.s3.amazonaws.com/radarlint/v2.0.0/radarlint.tar.gz`, compiled for Java 22+
  (nixpkgs' `jdk25_headless`). Java takes its home from the password database, not `HOME`: SonarLint fails to create
  `<home>/.sonarlint` in a sandbox, so the wrapper passes `-Duser.home="$HOME"`. Its telemetry is disabled at start.
- radarlint creates `work/` beside its jar, found through the jar's real path (the JVM resolves symlinks): from the
  store it fails ("Read-only file system"). The wrapper copies the jar into a directory of its own per run (plugins
  linked), removed after it. qlty passes plugins only `HOME` and proxies, not `TMPDIR`, and the Nix sandbox has no
  `/tmp`: the wrapper falls back to `HOME`.
- radarlint reads `radarlint.properties` from its working directory: `radarlint.rules.python.S3776=false` turns the
  rule off. qlty symlinks `.qlty/configs/<config file>` into the repo root while the plugin runs (when the plugin
  definition lists it in `config_files` and the root has none), then removes it.
- A plugin definition with no `runtime`, `releases` or `downloads` is a "null tool": qlty runs its `script` through
  `sh -c` with an empty-ish PATH and downloads nothing; `version` must be set.
- qlty's `[smells.*]` defaults are in its `qlty-config/default.toml`; Rust overrides `nodes_threshold` to 50 per
  language, which stays.

## Decisions

- Packages: `nix/qlty.nix` (the static x86_64 musl binary, wrapped to set `QLTY_TELEMETRY=off`; `meta.platforms`
  x86_64-linux; BSL 1.1 not set as `meta.license`, which nixpkgs counts as unfree and would make every repo allow
  unfree packages) and `nix/radarlint.nix` (the tarball, plus a `radarlint` wrapper over `jdk25_headless`). Flake
  outputs `packages.<system>.qlty` and `.radarlint`.
- The module's `findings` default check: `exec = "assay builtin findings"`, not fast; its tools: qlty where it is
  available, radarlint only when `languages.python.enable` or `languages.scala.enable` (a JDK in every repo's devenv
  otherwise). Elsewhere than x86_64-linux qlty is missing and the check exits 127.
- `ASSAY_CONFIG` gains an optional `findings` object, plain data with no store path (so `test/defaults/*.json` stay
  comparable): `radarlint` (languages), `rules` (radarlint rule key to on/off), `smells` (kind to `enable` and
  `threshold`), `duplication.nodes_threshold`. Absent fields write nothing, so qlty's defaults hold. assay renders
  `.qlty/qlty.toml` and `.qlty/configs/radarlint.properties` from it on every run, and finds radarlint on the PATH
  (resolved to an absolute path for qlty's empty PATH).
- Options: `assay.findings.smells.<kind>.{enable,threshold,reason}` for qlty's eight kinds,
  `assay.findings.smells.duplication.{nodes_threshold,reason}`, `assay.findings.rules.<key>.{enable,reason}` with
  `python:S3776` and `scala:S3776` off by default. Raising a threshold, turning a smell off or turning a rule off is a
  loosening: a `{check = "findings"; kind = "setting"; what; reason}` entry, which fails evaluation without a reason
  and which `assay check` prints as `loosening: findings <what>: <reason>`.
- New finding: a linter's finding (radarlint) is new when any of its lines is new code (assay's own new code, which
  follows renames), as qlty keeps them to changed lines; a start-line rule missed a parameter list growing past
  radarlint's S107 on its last lines. A smell is new when the base has no counterpart: the same rule, base path
  (through renames) and function name (none for nested control flow and boolean logic, whose regions qlty truncates
  to the first operands); for a clone's place, a clone's place in the same base path between the same set of base
  paths. Not `structural_hash`: appending code to a file whose whole module was a clone turned the clone into the
  function's, with another hash. Counted as multisets: with more at HEAD than at the base, those not starting on new
  code take the counterparts first. So a smell the base has, grown or edited, never fails. A nested block or a
  boolean expression is also new when it starts on new code: without a function, a block that replaces another of
  the same file would otherwise pass (the first critic's failure).
- radarlint's rules end its script as a shell comment (`# rules: python:S3776=false ...`): qlty keys its cache of a
  plugin's results by the script, not by `.qlty/configs/radarlint.properties`, so a rule turned back on did not show
  while the cache held the file (the first critic's failure).
- duplication's `nodes_threshold` holds for every language: assay writes it for Rust too, whose qlty default is 50,
  since #52 makes values per repo, not per language, and the issue names 64.
- The base's smells: `git read-tree` of the base into a temporary index, `checkout-index --prefix` into a temporary
  directory, `git init` there, the same `.qlty/qlty.toml`, `qlty smells <base paths>`, only when a function, file or
  clone finding needs a counterpart.
- `.git/info/exclude` (`git rev-parse --git-path info/exclude`) gets a `.qlty/` line before `.qlty/` is written. A
  repo that tracks `.qlty/qlty.toml` is exit 2: assay would overwrite it.
- Output: text by default, sorted by file, a blank line between files; in each file the lint findings, then the
  smells, by line: `path:line: tool/rule: message`, a clone's message followed by its locations. A finding that does
  not fail the check ends in `(not on new code)` or `(at the base too)`. Last line: the count and how many are new.
  `--sarif`: `{"version": "2.1.0", "runs": [lint, smells]}`, each result with SARIF's `baselineState` (`new` or
  `unchanged`). `assay builtin findings` prints the new ones only and exits 1 when there is any.
- Exit codes: `assay findings` 0 whenever it ran, 2 when it could not (qlty missing included);
  `assay builtin findings` 0, 1, 2, and 127 when qlty (or radarlint, when the configuration names it) is missing.

## Remaining steps

Done: everything the issue asks for, the code review and its fixes, a first critic (Done failed on the two points
above, now fixed; Resume, Verbatim and Differential passed). `main` moved meanwhile (the guard, #22): it is merged into
the branch.

1. A fresh critic rechecks the two failures, the diff of their fix and the merge's conflict resolution.
2. Remove this file once that recheck passes.
