{
  lib,
  writeShellApplication,
  ast-grep,
  coreutils,
  gawk,
  git,
  jq,
  yq-go,
  python3,
  flock,
  util-linux,
  stdenv,
}:
writeShellApplication {
  name = "assay";
  # No runtimeInputs: they would come first on the PATH of every check too. The script puts these first on its own
  # PATH and runs each check with the PATH it was called with. ast-grep matches the guard's command rules and runs
  # the ast-grep check; yq reads sgconfig.yml for that check and for `assay rule new`. assay_presets is where
  # `assay preset` finds every version of each language's preset.
  text = ''
    assay_tools=${
      lib.makeBinPath [
        ast-grep
        coreutils
        gawk
        git
        jq
        yq-go
        flock
      ]
      + lib.optionalString stdenv.isLinux ":${lib.getBin util-linux}/bin"
    }
    assay_presets=${../preset}
    assay_schema=${../schema}
    assay_collect=${../collector}/main.py
    assay_python=${python3.withPackages (p: [ p.jsonschema ])}/bin/python3
  ''
  + builtins.readFile ../assay.sh;
  derivationArgs.postCheck = ''
    install -Dm644 ${../schema/measure.json} "$out/share/assay/schema/measure.json"
    install -Dm644 ${../schema/collect.sql} "$out/share/assay/schema/collect.sql"
    install -Dm644 ${../dashboard.json} "$out/share/assay/dashboard.json"
  '';
  meta = {
    description = "A repo's named checks, run the same way from pre-commit, devenv test and an agent's shell";
    license = lib.licenses.mit;
    mainProgram = "assay";
  };
}
