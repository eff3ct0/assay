# qlty, the analyzer behind `assay findings`: not in nixpkgs, so its static musl release binary, at a pinned version
# moved on purpose (qlty releases several times a week). To move it: set `version`, and `sha256` to the release's own
# qlty-x86_64-unknown-linux-musl.tar.xz.sha256. The wrapper sets QLTY_TELEMETRY=off on every run: by default qlty sends
# usage events and errors to its backends.
#
# qlty's license is the Business Source License 1.1, whose grant allows this internal use. It is not set as
# meta.license: nixpkgs counts it as unfree, which would make every repo that imports assay's module allow unfree
# packages.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "qlty";
  version = "0.671.0";

  src = fetchurl {
    url = "https://github.com/qltysh/qlty/releases/download/v${finalAttrs.version}/qlty-x86_64-unknown-linux-musl.tar.xz";
    sha256 = "c5bbb492fcd5a88917b29592b01e1503162616d3f8401960715ef971a81b8120";
  };

  nativeBuildInputs = [ makeWrapper ];

  # A static binary: nothing to patch.
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 qlty $out/libexec/qlty/qlty
    makeWrapper $out/libexec/qlty/qlty $out/bin/qlty --set QLTY_TELEMETRY off
    runHook postInstall
  '';

  meta = {
    description = "Code quality CLI: linters and smells, run by assay findings";
    homepage = "https://github.com/qltysh/qlty";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "qlty";
  };
})
