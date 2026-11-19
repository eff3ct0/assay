# The devenv module a repo imports: `inputs.assay: { url: github:eff3ct0/assay, flake: false }` and
# `imports: [ assay/devenv ]` in its devenv.yaml. devenv reads this file from the input's source.
{
  imports = [
    (import ./module.nix { defaults = import ./defaults.nix; })
    ./uv-sync.nix
  ];
}
