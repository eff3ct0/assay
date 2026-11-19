# The helpers the default checks run (devenv/bin): assay-files, assay-nixf-tidy, assay-bats.
{ runCommandLocal }:
runCommandLocal "assay-check-helpers" { } ''
  mkdir -p $out/bin
  cp ${../devenv/bin}/* $out/bin/
  patchShebangs $out/bin
''
