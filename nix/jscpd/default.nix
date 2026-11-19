{
  buildNpmPackage,
  lib,
}:
buildNpmPackage {
  pname = "jscpd";
  version = "4.0.8";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
    ];
  };
  npmDepsHash = "sha256-7iSa+BOTZ3b79iAx7ZMT15knY42pfOKAIJKpugCf9yc=";
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/jscpd" "$out/bin"
    cp -R node_modules "$out/lib/jscpd/"
    ln -s ../lib/jscpd/node_modules/jscpd/bin/jscpd "$out/bin/jscpd"
    runHook postInstall
  '';
  meta = {
    description = "Copy/paste detector for source code";
    license = lib.licenses.mit;
    mainProgram = "jscpd";
  };
}
