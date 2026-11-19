# assay's check builder, flake.nix's lib.rulesCheck: a derivation that feeds every example of a rendered rule list
# (a home-manager configuration's programs.assay.rulesFile) to the real entrypoints, through rules-check.sh, and fails
# when a deny example passes or an allow example is denied. It takes seconds and needs no KVM, so a configuration's CI
# can build it. Its output is the report. `assay` is the package whose entrypoints it runs: by default the one the
# home-manager module installs by default, built with assay's own nixpkgs (command rules depend on its ast-grep); a
# configuration that sets programs.assay.package passes the same package here.
self:
{
  pkgs,
  rules,
  assay ? self.packages.${pkgs.stdenv.hostPlatform.system}.assay,
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
