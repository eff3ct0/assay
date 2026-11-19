# assay's check builder, flake.nix's lib.rulesCheck: a derivation that feeds every example of a rendered rule list
# (a home-manager configuration's programs.assay.rulesFile) to the real entrypoints, through rules-check.sh, and fails
# when a deny example passes or an allow example is denied. It takes seconds and needs no KVM, so a configuration's CI
# can build it. Its output is the report.
{
  pkgs,
  rules,
  assay ? pkgs.callPackage ./package.nix { },
}:
pkgs.runCommand "assay-rules-check"
  {
    nativeBuildInputs = [
      assay
      pkgs.bash
      pkgs.coreutils
      pkgs.git
      pkgs.jq
    ];
  }
  ''
    if ! bash ${./rules-check.sh} ${rules} >report; then
      cat report
      exit 1
    fi
    cat report
    mv report $out
  ''
