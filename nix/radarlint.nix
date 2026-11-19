# radarlint: SonarSource's analyzers (sonar-python, sonar-scala and others) behind one CLI, which qlty's radarlint
# plugins run. qlty would download it, and a Java runtime, at run time; assay points its plugins at this package
# instead. The archive is the one qlty's plugin definitions name for this version; it publishes no checksum, so the
# hash is the archive's own.
{
  lib,
  stdenvNoCC,
  fetchurl,
  jdk25_headless,
  runtimeShell,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "radarlint";
  version = "2.0.0";

  src = fetchurl {
    url = "https://radarlint-releases.s3.amazonaws.com/radarlint/v${finalAttrs.version}/radarlint.tar.gz";
    sha256 = "0804a5ac6da05e1b176a03bd6295c7f0c44ca0605af62272f708048ea1540cb2";
  };

  sourceRoot = ".";

  # radarlint.jar finds the analyzers in plugins/, beside it. Java takes its home from the password database, not
  # HOME, and SonarLint keeps its storage there: HOME it is, which a sandbox can write. Its classes need Java 22 or
  # later.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/radarlint $out/bin
    cp -r radarlint.jar plugins $out/share/radarlint/
    cat >$out/bin/radarlint <<EOF
    #!${runtimeShell}
    exec ${lib.getExe' jdk25_headless "java"} -Duser.home="\$HOME" -jar $out/share/radarlint/radarlint.jar "\$@"
    EOF
    chmod +x $out/bin/radarlint
    runHook postInstall
  '';

  meta = {
    description = "SonarSource's analyzers behind one CLI, as qlty's radarlint plugins run them";
    homepage = "https://github.com/qltysh/qlty/tree/main/qlty-plugins/plugins/linters/radarlint-python";
    platforms = jdk25_headless.meta.platforms;
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
    mainProgram = "radarlint";
  };
})
