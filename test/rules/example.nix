# The example rule list: one or more rules of each `on`, written as a machine's home-manager configuration writes
# programs.assay.rules. nix/checks.nix renders it through the home-manager module and compares the result with
# example.json, which the bats suite reads. Generic on purpose: no real machine's list.
let
  noClone = {
    kind = "command";
    all = [
      {
        has = {
          field = "name";
          regex = "^git$";
        };
      }
      {
        has = {
          kind = "word";
          regex = "^(clone|worktree)$";
        };
      }
    ];
  };
  gitWord = regex: {
    kind = "command";
    all = [
      {
        has = {
          field = "name";
          regex = "^git$";
        };
      }
      {
        has = {
          kind = "word";
          inherit regex;
        };
      }
    ];
  };
  shaped = "# app\n\n## Related repos\n\nNone.\n";
in
[
  {
    name = "no-clone";
    on = "command";
    match = noClone;
    message = "Get repos and worktrees through the workspace tool, not git clone or git worktree.";
    note = "Why: the workspace keeps one clone per repo.\nFix: use the workspace tool.\nNot a fix: wrapping the call in a script. If the rule is wrong here, stop and tell the user.";
    deny = [
      "cd x && git clone y"
      "git -C r worktree add ../x"
    ];
    allow = [
      ''git commit -m "explain git clone"''
      "git status"
    ];
  }
  {
    name = "main-checkout-edit";
    on = "path";
    match = "main-checkout";
    message = "The main checkout stays clean: edit files in a worktree of your own.";
    deny = [ "repo/README.md" ];
    allow = [
      "worktree/README.md"
      "notes.md"
    ];
  }
  {
    name = "no-env-file";
    on = "path";
    match = "*.env";
    message = "Environment files hold secrets: do not write them.";
    who = "everyone";
    deny = [ "repo/.config/prod.env" ];
    allow = [ "repo/env.example" ];
  }
  {
    name = "main-checkout-commit";
    on = "command";
    match = gitWord "^(commit|merge|rebase|reset|switch)$";
    cwd = "main-checkout";
    message = "The main checkout stays on its default branch: commit in a worktree of your own.";
    deny = [
      {
        command = "git commit -m x";
        cwd = "repo";
      }
    ];
    allow = [
      {
        command = "git commit -m x";
        cwd = "worktree";
      }
      {
        command = "git pull";
        cwd = "repo";
      }
    ];
  }
  {
    name = "pr-attribution";
    on = "command";
    match = {
      kind = "command";
      all = [
        {
          has = {
            field = "name";
            regex = "^gh$";
          };
        }
        {
          has = {
            kind = "word";
            regex = "^pr$";
          };
        }
        {
          has = {
            kind = "word";
            regex = "^(create|edit)$";
          };
        }
        {
          any = [
            {
              has = {
                regex = "(?i)generated with";
                follows.regex = "^(--body|-b)$";
              };
            }
            {
              has = {
                pattern = "$FILE";
                follows.regex = "^(--body-file|-F)$";
              };
            }
            {
              has = {
                pattern = "$FILE";
                regex = "^--body-file=";
              };
            }
          ];
        }
      ];
    };
    fileContent = "(?i)generated with";
    message = "A pull request's description names no tool that wrote it.";
    deny = [
      "gh pr create --title t --body 'Fix.\n\nGenerated with a tool'"
      {
        command = "gh pr create --title t --body-file body.md";
        files."body.md" = "Fix.\n\nGenerated with a tool\n";
      }
    ];
    allow = [
      "gh pr create --title t --body 'Fix the parser.'"
      {
        command = "gh pr edit 3 --body-file body.md";
        files."body.md" = "Fix the parser.\n";
      }
    ];
  }
  {
    name = "no-coauthor";
    on = "commit-msg";
    match = "(?im)^co-authored-by:";
    message = "A commit names no co-author: remove the Co-Authored-By trailer.";
    who = "everyone";
    deny = [ "Fix the parser\n\nCo-Authored-By: A <a@example.com>\n" ];
    allow = [
      "Fix the parser\n\nReviewed-by: A <a@example.com>\n"
      "Fix the co-authored-by: parser\n"
    ];
  }
  {
    name = "agent-branch";
    on = "pre-push";
    match = "agent-branch";
    message = "Agent branches start with agent/: push your work as agent/<topic>.";
    deny = [ "refs/heads/feature" ];
    allow = [
      "refs/heads/agent/feature"
      "refs/heads/main"
      "refs/tags/v1"
    ];
  }
  {
    name = "agents-md-shape";
    on = "pre-push";
    match = "agents-md";
    message = "Every repo has AGENTS.md with the instructions and CLAUDE.md as the single line @AGENTS.md.";
    deny = [
      {
        files = {
          "AGENTS.md" = shaped;
          "CLAUDE.md" = shaped;
        };
      }
    ];
    allow = [
      {
        files = {
          "AGENTS.md" = shaped;
          "CLAUDE.md" = "@AGENTS.md\n";
        };
      }
    ];
  }
  {
    name = "save-work";
    on = "stop";
    match = "unsaved-work";
    message = "Commit and push your branch before you stop, unfinished work included (wip: ...).";
    deny = [
      { uncommitted = true; }
      { unpushed = true; }
    ];
    allow = [
      { }
      {
        unpushed = true;
        remote = false;
      }
    ];
  }
]
