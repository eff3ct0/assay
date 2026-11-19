# assay's own checks: Nix's and bash's default checks, run by the version of assay this tree ships (devenv.yaml
# imports ./devenv). Its bats suite is bash's test check, which runs every .bats file, test/devenv's included.
{ pkgs, ... }:
{
  languages.nix.enable = true;
  languages.shell.enable = true;

  # What the tests run beside the checks' own tools.
  packages = with pkgs; [
    # ast-grep and yq: the suite runs assay.sh, which finds them on the PATH.
    ast-grep
    git
    jq
    # Bootstrap the Python integration fixture before its pyproject.toml exists.
    uv
    # The suite runs radarlint, which the module brings only to repos with Python or Scala.
    (callPackage ./nix/radarlint.nix { })
    # And TLC, which it brings only to repos that turn the tla check on: assay has no model of its own.
    tlaplus18
    yq-go
  ];
}
