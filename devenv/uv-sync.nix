{ config, lib, ... }:
let
  python = config.languages.python;
in
{
  options.assay.python.uv.syncIfManifest =
    lib.mkEnableOption "skipping uv synchronization until pyproject.toml exists";

  config =
    lib.mkIf (config.assay.python.uv.syncIfManifest && python.enable && python.uv.sync.enable)
      {
        # A successful status tells devenv the task has nothing to do. Otherwise its normal exec runs.
        # Exit explicitly: devenv appends its environment export script to status commands too.
        tasks."devenv:python:uv".status =
          "if test -f ${lib.escapeShellArg "${python.directory}/pyproject.toml"}; then exit 1; fi";
      };
}
