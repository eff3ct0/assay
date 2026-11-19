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
      # qlty and radarlint are the tools of the built-in `findings` check; qlty only where its static binary runs.
      packages = forAllSystems (
        pkgs:
        let
          qlty = pkgs.callPackage ./nix/qlty.nix { };
        in
        rec {
          assay = pkgs.callPackage ./nix/package.nix { };
          default = assay;
          radarlint = pkgs.callPackage ./nix/radarlint.nix { };
        }
        // nixpkgs.lib.optionalAttrs (nixpkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform qlty) {
          inherit qlty;
        }
      );

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
          packages =
            with pkgs;
            [
              bats
              shellcheck
              nixfmt
              jq
              git
              gawk
              # The built-in checks' tools, which assay's devenv module adds to every repo's devenv (radarlint to those
              # with Python or Scala).
              actionlint
              gitleaks
              oxfmt
            ]
            ++ builtins.attrValues (
              removeAttrs self.packages.${pkgs.stdenv.hostPlatform.system} [
                "assay"
                "default"
              ]
            );
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
