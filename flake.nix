{
  description = "assay: a repo's named checks, run the same way from pre-commit, devenv test and an agent's shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        assay = pkgs.callPackage ./nix/package.nix { };
        default = assay;
      });

      # No output for the devenv module: a repo imports devenv/ by path from this repo's source
      # (`imports: [ assay/devenv ]` in its devenv.yaml).

      checks = forAllSystems (
        pkgs:
        import ./nix/checks.nix {
          inherit pkgs;
          src = ./.;
        }
        // {
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.assay;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            bats
            shellcheck
            nixfmt
            jq
            git
            gawk
            # The guard's command rules run through it; the package brings it on its own.
            ast-grep
            # The built-in checks' tools, which assay's devenv module adds to every repo's devenv.
            actionlint
            gitleaks
            oxfmt
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
