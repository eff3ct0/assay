{
  config,
  lib,
  pkgs,
}:
lib.optionalAttrs (config.languages.scala.enable or false) (
  lib.mapAttrs (_: check: { requires = "build.sbt"; } // check) {
    scalafmt = {
      # Use scalafmt's native-image version check on the JVM: even for complex HOCON, a mismatch prints the
      # bundled version to set instead of starting the dynamic (downloading) runner.
      exec = ''JDK_JAVA_OPTIONS="''${JDK_JAVA_OPTIONS:-} -Dscalafmt.native-image=true" scalafmt --test'';
      fast = true;
      packages = [ pkgs.scalafmt ];
    };
    scala-compile = {
      exec = "env -u SBT_TPOLECAT_DEV sbt --server --batch ';compile;Test/compile'";
      packages = [ (config.languages.scala.sbt.package or pkgs.sbt) ];
    };
    scalafix.exec = "env -u SBT_TPOLECAT_DEV sbt --server --batch 'scalafixAll --check'";
    scala-test = {
      exec = ''
        set -o pipefail
        env -u SBT_TPOLECAT_DEV sbt --server --batch --no-colors \
          ';set Global / cacheStores := Seq.empty;coverage;testFull;coverageReport' | tee "$ASSAY_DIR/sbt-coverage.log" &&
        ${pkgs.python3}/bin/python ${./scala-coverage.py} "$ASSAY_DIR"
      '';
      coverage = "$ASSAY_DIR/scala-cobertura.xml";
    };
  }
)
