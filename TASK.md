# Task: `assay guard`, `assay git-hook`, and the home-manager module's rule list

Remove this file once the last critic passes.

## The request, verbatim

> /mattpocock-skills:implement https://github.com/eff3ct0/assay/issues/12

Issue #12 and the specifications it links (eff3ct0/nixos-config#49, #50, #51, #53) are the spec. The skill asks for
test-first work at the seams `AGENTS.md` names (bats for the CLI, `nix flake check` for the modules), the full suite at
the end, a `code-review` pass, and a commit to this branch.

## Decisions (the issue's "Left to implementation")

- **Pre-push and Stop checks in the rule list**: two more values of `on`. `on = "pre-push"` takes `match` =
  `agent-branch` (every pushed `refs/heads/*` is `agent/*` or the remote's default branch; tags and other refs pass)
  or `agents-md` (each pushed branch tip's tree has the shape, through `agents_md_problems`). `on = "stop"` takes
  `match` = `unsaved-work` (the cwd's worktree has uncommitted changes, untracked files included, or, with a remote,
  commits on no remote-tracking ref). The hits log records the rule's own `name`, as for every rule.
- **A command rule that needs the cwd in a main checkout**: an optional `cwd` field on `command` rules, a glob or
  `main-checkout`, matched against the event's `cwd`; the rule applies only when it matches.
- **`--body-file`**: an optional `fileContent` field on `command` rules, a regex. A match that binds the ast-grep
  metavariable `$FILE` counts only when the file it names (relative to the cwd; quotes and a `--opt=` prefix removed)
  holds text matching it; a match that binds no `$FILE` counts as usual, so one rule covers `--body` and
  `--body-file` through `any`.
- **The check builder**: `lib.rulesCheck { pkgs, rules }` in the flake, `rules` the rendered JSON file
  (`config.programs.assay.rulesFile`), building `assay-rules-check`. It runs `nix/rules-check.sh`, which feeds each
  example to the real entrypoint with its rule alone, in a fresh fixture: `repo/` (a main checkout on `main`, pushed
  to `origin.git`), `worktree/` (a linked worktree on `agent/example`, pushed) and `local/` (no remote), under one
  root that is the default cwd.
- **`permissionDecisionReason`** (and Stop's `reason`, and git-hook's stderr): the message, any detail lines, then the
  note after a blank line. Every violated rule is reported, one hit line each.
- **Examples**: a string or an attribute set, normalised to objects when rendered. `command`: `{ command; cwd; files }`;
  `path`: `{ path; cwd }`; `commit-msg`: `{ message }`; `pre-push`: `{ ref ? "refs/heads/agent/example"; files }`
  (the tip's root files over a tree with the shape; `null` removes one); `stop`: `{ uncommitted; unpushed; remote }`
  (attribute set only).
- **Globs** (`path` match, `cwd`): `*` and `?` stay within a component, `**` crosses them; no `/` matches the file's
  name, a leading `/` the whole absolute path, anything else the path's end at a component boundary.
- **Regexes** (`commit-msg`, `fileContent`): jq's (Oniguruma, Perl syntax): `(?i)`, `(?m)` for `^`/`$` at each line.
- **commit-msg** reads the message as git will store it: cut at the scissors line, comments stripped.
- **Errors**: `guard` exits 1 on any error of its own, never 2 (Claude Code blocks on 2); `git-hook` exits 1 with
  `assay: cannot evaluate rules: …`, an unknown hook name included.
- **Home-manager module** (`nix/home-manager.nix`, exported as `homeManagerModules.default`): `enable`, `package`,
  `rules`, read-only `rulesFile`; git hooks through `programs.git.settings.hook.*` with the package's absolute path
  (a warning when `programs.git.enable` is off); `ASSAY_HITS_LOG` through `home.sessionVariables`, with mkDefault.
  ast-grep joins the package's own tools.

## Remaining steps

Done: the guard, the git hooks, hits, `nix/rules-check.sh`, the home-manager module, `lib.rulesCheck`, their tests and
nix checks, README, AGENTS.md, GLOSSARY, usage text; the full runs (`nix flake check`, `devenv shell -- assay check`,
`nix develop -c bats test/devenv`); the `code-review` skill over `b93c455..HEAD` and its fixes (`67bdb7d`,
`1e96d11`); the first critic (Done, Verbatim and Differential pass; Resume failed on this section, now current).

1. A fresh critic rechecks the Resume failure and the diff of its fix (`~/git/CLAUDE.md`, "After the critic").
2. Once the recheck passes, remove this file in a commit of its own, push, and report to p3rkins with the open
   decisions the critic and the code review raised: `main-checkout` cannot be limited to one directory (a path rule
   takes a glob or the predicate, not both); tags skip the `agents-md` pre-push check; the git hooks run the
   package's absolute path rather than a bare `assay`; the rule format is validated in three places (`assay.sh`,
   `nix/home-manager.nix`, `nix/rules-check.sh`).
