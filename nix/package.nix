{
  lib,
  writeShellApplication,
  ast-grep,
  coreutils,
  gawk,
  git,
  jq,
}:
writeShellApplication {
  name = "assay";
  # No runtimeInputs: they would come first on the PATH of every check too. The script puts these first on its own
  # PATH and runs each check with the PATH it was called with. ast-grep is the guard's: it matches command rules.
  text = ''
    assay_tools=${
      lib.makeBinPath [
        ast-grep
        coreutils
        gawk
        git
        jq
      ]
    }
  ''
  + builtins.readFile ../assay.sh;
  meta = {
    description = "A repo's named checks, run the same way from pre-commit, devenv test and an agent's shell";
    license = lib.licenses.mit;
    mainProgram = "assay";
  };
}
