# Task: `assay check` (issue #1)

Temporary: removed once the last critic passes.

## Request, verbatim

> Implement https://github.com/eff3ct0/assay/issues/1. Read the repo's AGENTS.md first and follow ~/git/AGENTS.md:
> grove worktree on an agent/ branch, a critic before handing over, a pull request for the user to merge.

Base commit: `bca17dd` (`chore: init`). Branch: `agent/assay-check`.

## Decisions

- Layout like grove's: `assay.sh` at the root (bash + jq), `nix/package.nix` (`writeShellApplication`, built with
  `callPackage`), `nix/checks.nix` for `nix flake check`, `flake.nix` with `packages.{assay,default}`, `checks`,
  `devShells.default`, `formatter`. No `homeManagerModules` (the guard issue) and no devenv files for assay itself
  (issue #2, adopter zero).
- The package prepends `assay_tools=<bin path of git, jq, coreutils>` to the script; the script puts it first on
  its own PATH and runs each check with the caller's PATH, so the checks see the devenv's tools, not assay's.
- Config JSON (`ASSAY_CONFIG`): `{ "version": 1, "checks": { <name>: { exec, fast, enable, requires } },
  "loosenings": [ { check, kind: "off" | "exec", reason } ] }`. The CLI validates the shape with jq and exits 2 on
  anything else (fails closed). Check names match `[A-Za-z0-9][A-Za-z0-9._-]*` (they become log file names).
- Defaults: `devenv/defaults.nix` (`{ config, lib, pkgs }: { <name> = { exec; fast; enable?; requires?; }; }`),
  empty for now. `devenv/module.nix` takes the defaults file as an argument, so `nix/checks.nix` can evaluate it with
  test defaults; `devenv/devenv.nix` applies it to `defaults.nix`. Each default field is set with `lib.mkDefault`.
  Loosening reason: `assay.checks.<name>.reason`. Evaluation fails (throw) on a loosening without one.
- `assay.seed`: positive 32-bit integer (every PBT library accepts it), default 42, exported as `ASSAY_SEED`.
- `requires` is matched with git's `:(glob)` pathspec against the files git sees in the working tree (tracked and
  untracked, not ignored), existing on disk.
- The resolved base's full sha is exported to each check as `ASSAY_BASE`.
- Output: header `assay check[ --fast][ <names>] · base <label>@<short> (<source>)`, then indented
  `loosening:` and `skipped:` lines; one line per check (`ok  `, `FAIL`, `skip` padded to 4, name, seconds; FAIL
  adds `(exit N)`, `127: tool not found`); `skip <name> (no <glob>)` verbatim; failure details after all checks;
  last line with the count, total seconds and, on failure, `rerun: assay check [--base <rev>] <names>`.
- `--list` takes no other argument. Naming an unknown or disabled check is exit 2; with `--fast`, naming a check
  that is not fast is exit 2.
- Tests: `test/*.bats` hermetic (hand-written configs, throwaway repos; run by `nix flake check`);
  `test/devenv/*.bats` integration through devenv 2.4.0 and a `git+file:` copy of the working tree (network,
  not in the sandbox). Consumer nixpkgs pinned to this flake's `flake.lock` rev.
- `AGENTS.md` filled in and `CLAUDE.md` = `@AGENTS.md` (required by ~/git/AGENTS.md); issue #2 extends them.

## Remaining steps

1. `assay.sh`, `nix/package.nix`, `flake.nix` + `flake.lock`, `nix/checks.nix`.
2. `devenv/devenv.nix`, `devenv/module.nix`, `devenv/defaults.nix`, `devenv/devenv.yaml`.
3. bats: `test/check.bats`, `test/base.bats`, `test/devenv/module.bats`, helpers.
4. `AGENTS.md`, `CLAUDE.md`, `README.md`.
5. Run everything; critic; fixes; recheck critic; PR.
