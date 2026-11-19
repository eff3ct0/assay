# assay's own checks: Nix's and bash's default checks, run by the version of assay this tree ships (devenv.yaml
# imports ./devenv). Its bats suite is bash's test check, which runs every .bats file, test/devenv's included.
{ pkgs, ... }:
{
  languages.nix.enable = true;
  languages.shell.enable = true;

  # What the tests run beside the checks' own tools.
  packages = with pkgs; [
    # ast-grep: the guard's tests run assay.sh, which finds it on the PATH.
    ast-grep
    git
    jq
    # The suite runs radarlint, which the module brings only to repos with Python or Scala.
    (callPackage ./nix/radarlint.nix { })
  ];
}
