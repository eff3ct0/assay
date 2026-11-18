# assay's default checks, as a function of { config, lib, pkgs } returning
# { <name> = { exec; fast; enable ? true; requires ? null; coverage ? null; packages ? [ ]; }; }. The module sets
# each field but packages with lib.mkDefault, so a plain definition in the repo overrides it; turning one off,
# redefining its exec or changing its coverage is a loosening, which needs `assay.checks.<name>.reason`. packages
# are the tools the check needs, which the module adds to the devenv. The built-in and per-language defaults join
# here later.
_: { }
