# assay's own checks, run by the version of assay this tree ships (devenv.yaml imports ./devenv).
{ pkgs, ... }:
{
  packages = with pkgs; [
    bats
    git
    jq
  ];

  # assay's bats suite (test/), until the bash default checks replace it.
  assay.checks.bats.exec = "bats test";
}
