# Rule packs

A rule pack is an opt-in set of ast-grep rules that assay ships, for rules that hold for every repo of a language. A
repo turns one on in its `devenv.nix`:

```nix
{
  assay.rulePacks = [ "<name>" ];
}
```

The `ast-grep` check then tests the pack and scans the repo with its rules, beside the repo's own. A pack adds rules:
what they find in the repo is cleaned up in the change that turns it on, as for a new rule.

## Layout

Each pack is a directory here, named as the repo turns it on, and an ast-grep project of its own:

```text
packs/<name>/
├── sgconfig.yml              # ruleDirs: [rules], testConfigs: [{testDir: rule-tests}]
├── rules/<rule>.yml          # one rule per file, severity error, its message and note as any rule's
└── rule-tests/<rule>-test.yml  # at least one invalid and one valid case
```

assay's suite runs every pack's tests (`test/packs.bats`).

## When a rule joins a pack

A rule is born in the repo where the correction happened. It moves here when the correction says it holds for every
repo of a language, or when a second repo needs it; the first repo then drops its copy and turns the pack on. A native
rule (clippy, ruff, ESLint…) that holds for every repo of a language joins that language's preset instead.

assay ships no pack yet. `test/packs/demo` is the one assay's tests turn on.
