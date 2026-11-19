# assay's own checks, run by the version of assay this tree ships (devenv.yaml imports ./devenv).
{ pkgs, ... }:
{
  packages = with pkgs; [
    bats
    git
    jq
    # The suite runs radarlint, which the module brings only to repos with Python or Scala.
    (callPackage ./nix/radarlint.nix { })
  ];

  # assay's bats suite (test/), until the bash default checks replace it.
  assay.checks.bats.exec = "bats test";
}
