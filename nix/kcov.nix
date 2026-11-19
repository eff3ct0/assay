# kcov with the fix for ANSI-C quoted strings in bash's trace (kcov-ansi-c-quote.patch), without which bats 1.14
# loses the coverage of everything after its first `run`. Drop the patch once nixpkgs' kcov includes it.
{ kcov }:
kcov.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./kcov-ansi-c-quote.patch ];
})
