# Task: issue #2, assay adopts itself and reaches a repo from outside its devenv

Removed once the last critic passes.

## The request, verbatim

```
/mattpocock-skills:implement https://github.com/eff3ct0/assay/issues/2
```

The issue (with its comment deciding the license: MIT, "Copyright (c) 2026 the assay contributors",
`meta.license = lib.licenses.mit`, a "License" section in `README.md`) is the specification; read it and the
nixos-config issues it links.

## Decisions

- Delegation (`assay.sh`, `delegate`): `check` with `ASSAY_CONFIG` unset or empty finds the repo root
  (`git rev-parse --show-toplevel`), exits 2 when it has no `devenv.nix`, else runs, from the root,
  `devenv shell -- "$BASH" -c <wrapper> assay-delegate <marks-dir> <args>`. The wrapper, assay's own code, records
  in the marks dir whether the devenv set `ASSAY_CONFIG` (`unadopted`) and whether it handed over (`started`), then
  `exec assay "$@"`. So: `unadopted` → exit 2 naming the adoption procedure; no `started` and non-zero → devenv
  itself failed (exit 1 on an evaluation error, which must not pass for a failing check) → exit 2; `started` → the
  repo's assay's exit code (0, 1, 2 or 130 pass through, anything else → 2). The wrapper works whatever version
  of assay the repo pins, older ones included.
- `guard`, `git-hook`, `collect`: usage stubs, exit 2, never delegated.
- Hits log (`log_hit <source> <jq object> [jq args]`): one writer, reused by the guard issue. Common fields from
  jq (`time` is `now | todate`); `repo` from `git rev-parse --path-format=absolute --git-common-dir`, minus a
  trailing `/.git`, `null` outside a repo; `agent` is `ASSAY_AGENT`, `null` when unset or empty. Creates the
  file's directory; every failure is silent. `check` lines: one per run that got past argument parsing and is not
  `--list`, whatever its exit (0, 1, 2, 130), written by the process that runs the checks (never by the
  delegating one); `only` is the names as given (the spec: "the check names given"); `seconds` has two decimals.
  No line for usage errors, `--list`, help, or a delegation that never reached the repo's assay (not adopted,
  devenv failing): none of them ran the checks.
- Self-adoption: root `devenv.yaml` (nixpkgs `github:cachix/devenv-nixpkgs/rolling`, `git-hooks`,
  `imports: [ ./devenv ]`), root `devenv.nix` declaring the `bats` check (`bats test`) with bats, git and jq;
  `devenv.lock` committed. Checked by hand that devenv 2.4.0 imports `./devenv` and lists the check.
- Tests unset `ASSAY_HITS_LOG` and `ASSAY_AGENT`, so the suite run under a machine's environment never writes to
  its real log.

## Steps

1. [x] Delegation + exit 2 + stubs, with `test/stub/devenv` and `test/delegate.bats`.
2. [x] Hits log writer + check lines, `test/hits.bats`.
3. [x] Real devenv tests in `test/devenv/module.bats` (delegation, unadopted consumer).
4. [x] Self-adoption files, `.gitignore`, `devenv.lock`; `nix run . -- check --list`; `devenv test`; hook on commit.
5. [x] `check.yml`, `docs/adoption.md`, `GLOSSARY.md`, `AGENTS.md`, `README.md`, `LICENSE`, package license.
6. [x] `nix flake check` (patchShebangs and shellcheck the stub), `bats test/devenv`, genericity grep.
7. [ ] code-review skill, critic, push, PR (CI on the PR is an acceptance criterion).
