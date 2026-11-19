# assay's default checks, as a function of { config, lib, pkgs } returning
# { <name> = { exec; fast; enable ? true; requires ? null; coverage ? null; packages ? [ ]; }; }. The module sets each
# check field with lib.mkDefault, so a plain definition in the repo overrides it; turning one off, redefining its exec
# or changing its coverage is a loosening, which needs `assay.checks.<name>.reason`. `packages` are the tools the
# check runs, which join the repo's devenv whether the check is on or not. test/defaults/*.json hold the configuration
# these give, which nix/checks.nix compares with the module's and the bats suite runs. The built-in checks, which
# every repo runs, are here; each language's, on when the repo enables the language, in languages/.
args@{
  config,
  lib,
  pkgs,
}:
let
  javascript = config.languages.javascript or { enable = false; };

  # languages.javascript.directory (absolute, or relative to the devenv root, which is the repo root), relative to
  # the repo root: "" at the root.
  javascriptDir =
    let
      root = config.devenv.root;
      dir = javascript.directory;
      relative =
        if dir == root then
          ""
        else if lib.hasPrefix "${root}/" dir then
          lib.removePrefix "${root}/" dir
        else
          dir;
      trimmed = lib.removeSuffix "/" (lib.removePrefix "./" relative);
    in
    if trimmed == "." then "" else trimmed;

  # Markdown and YAML in every repo; a JavaScript project's own files under its directory. TOML never: cargo and uv
  # write it. The scope lives here, not in a configuration file, so that it is the same wherever .oxfmtrc.json sits.
  oxfmtPatterns = [
    "**/*.{md,mdx,yml,yaml}"
  ]
  ++ lib.optional javascript.enable (
    lib.optionalString (javascriptDir != "") "${javascriptDir}/"
    + "**/*.{js,jsx,mjs,cjs,ts,tsx,mts,cts,json,jsonc,json5,css,scss,less,html,vue}"
  );

  # The analyzer: qlty where its static binary runs; radarlint, a JVM, only for the languages it analyzes.
  qlty = pkgs.callPackage ../nix/qlty.nix { };
  radarlint = pkgs.callPackage ../nix/radarlint.nix { };
  radarlintNeeded = builtins.any (l: config.languages.${l}.enable or false) [
    "python"
    "scala"
  ];
in
{
  # GitHub workflows: syntax, expressions, and shellcheck over `run:` blocks (nixpkgs wraps actionlint with it).
  actionlint = {
    exec = "actionlint";
    fast = true;
    requires = ".github/workflows/*";
    packages = [ pkgs.actionlint ];
  };
  agents-md = {
    exec = "assay builtin agents-md";
    fast = true;
  };
  # The repo's ast-grep rules, whose opt-in is sgconfig.yml, and the rule packs it turns on (assay.rulePacks), which
  # are an opt-in of their own.
  ast-grep = {
    exec = "assay builtin ast-grep";
    fast = true;
    requires = if config.assay.rulePacks == [ ] then "sgconfig.yml" else null;
    packages = [ pkgs.ast-grep ];
  };
  commit-trailers = {
    exec = "assay builtin commit-trailers";
    fast = true;
  };
  # The new findings among those `assay findings` shows; it builds nothing, but analyzes too slowly for every commit.
  findings = {
    exec = "assay builtin findings";
    fast = false;
    packages =
      lib.optional (lib.meta.availableOn pkgs.stdenv.hostPlatform qlty) qlty
      ++ lib.optional radarlintNeeded radarlint;
  };
  gitleaks = {
    exec = "assay builtin gitleaks";
    fast = true;
    packages = [ pkgs.gitleaks ];
  };
  # The fix is the same command without --check.
  oxfmt = {
    exec = lib.concatStringsSep " " (
      [ "oxfmt --check --no-error-on-unmatched-pattern" ] ++ map lib.escapeShellArg oxfmtPatterns
    );
    fast = true;
    packages = [ pkgs.oxfmt ];
  };
  suppressions = {
    exec = "assay builtin suppressions";
    fast = true;
  };
}
// import ./languages/nix.nix args
// import ./languages/bash.nix args
