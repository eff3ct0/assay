{
  lib,
  writeShellApplication,
  ast-grep,
  coreutils,
  gawk,
  git,
  jq,
  yq-go,
}:
writeShellApplication {
  name = "assay";
  # No runtimeInputs: they would come first on the PATH of every check too. The script puts these first on its own
  # PATH and runs each check with the PATH it was called with. ast-grep matches the guard's command rules and runs
  # the ast-grep check; yq reads sgconfig.yml and the Python preset's TOML manifest. assay_presets is where
  # `assay preset` finds every version of each language's preset. Project managers like uv come from the caller.
  text = ''
    assay_tools=${
      lib.makeBinPath [
        ast-grep
        coreutils
        gawk
        git
        jq
        yq-go
      ]
    }
    assay_presets=${../preset}
  ''
  + builtins.readFile ../assay.sh;
  meta = {
    description = "A repo's named checks, run the same way from pre-commit, devenv test and an agent's shell";
    license = lib.licenses.mit;
    mainProgram = "assay";
  };
}
