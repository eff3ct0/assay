{
  description = "assay: a repo's named checks, run the same way from pre-commit, devenv test and an agent's shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Only for the home-manager module's checks; consumers bring their own home-manager.
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
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

      # The machine-level part: the CLI, the rule list that `assay guard` and `assay git-hook` read, the global git
      # hooks and the hits log's path.
      homeManagerModules.default = import ./nix/home-manager.nix self;

      # The check builder: lib.rulesCheck { pkgs; rules = <home>.config.programs.assay.rulesFile; } builds
      # assay-rules-check, which fails when a deny example passes or an allow example is denied.
      lib.rulesCheck = import ./nix/rules-check.nix self;

      checks = forAllSystems (
        pkgs:
        import ./nix/checks.nix {
          inherit pkgs home-manager;
          src = ./.;
          module = self.homeManagerModules.default;
          rulesCheck = self.lib.rulesCheck;
        }
        // {
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.assay;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = import ./nix/test-tools.nix { inherit pkgs; };
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
