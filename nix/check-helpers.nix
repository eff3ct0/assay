# The helpers the default checks run (devenv/bin), including assay-pytest and assay-deptry.
{ runCommandLocal }:
runCommandLocal "assay-check-helpers" { } ''
  mkdir -p $out/bin
  cp ${../devenv/bin}/* $out/bin/
  patchShebangs $out/bin
''
