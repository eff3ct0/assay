# assay's default checks, as a function of { config, lib, pkgs } returning
# { <name> = { exec; fast; enable ? true; requires ? null; }; }. The module sets each field with lib.mkDefault, so a
# plain definition in the repo overrides it; turning one off or redefining its exec is a loosening, which needs
# `assay.checks.<name>.reason`. The built-in and per-language defaults join here later.
_: { }
