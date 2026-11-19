bats_require_minimum_version 1.5.0
# shellcheck source=test/devenv/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

scala_check() {
	local expected=$1
	shift
	run --separate-stderr devenv shell -- assay check --base HEAD "$@"
	printf '# %s\n' "${lines[@]}" >&3
	[ "$status" -eq "$expected" ]
}

@test "Scala: the sbt 2 fixture takes the preset and each check finds its defect" {
	consumer
	shape
	# The fixture needs the sbt 2 launcher. Use assay's devenv pin, rather than its older flake nixpkgs.
	rev=$(jq -r .nodes.nixpkgs.locked.rev "$ASSAY/devenv.lock")
	sed -i "s|NixOS/nixpkgs/$NIXPKGS_REV|cachix/devenv-nixpkgs/$rev|" devenv.yaml
	devenv_nix '{ languages.scala.enable = true; }'
	run --separate-stderr devenv shell -- assay check --list
	[ "$status" -eq 0 ]
	for check in scala-compile scalafix scala-test 'scalafmt (fast)'; do grep -Fx "$check" <<<"$output"; done
	scala_check 0 scala-compile scalafix scala-test scalafmt
	for check in scala-compile scalafix scala-test scalafmt; do grep -Fx "skip $check (no build.sbt)" <<<"$output"; done

	mkdir -p project src/{main,test}/scala
	echo sbt.version=2.0.12 >project/build.properties
	printf '%s\n' 'scalaVersion := "3.10.1"' \
		'libraryDependencies += "org.scalameta" %% "munit" % "1.3.6" % Test' >build.sbt
	devenv shell -- assay preset scala
	jq -e '. == {"scala":1}' .assay-preset.json
	version=$(devenv shell -- scalafmt --version)
	grep -Fx "version = ${version#scalafmt }" .scalafmt.conf
	src=src/main/scala/Calc.scala
	suite=src/test/scala/CalcSuite.scala
	printf '%s\n' 'object Calc {' '  def twice(n: Int): Int = n * 2' '}' >"$src"
	printf '%s\n' 'class CalcSuite extends munit.FunSuite {' '  test("twice") {' \
		'    assertEquals(Calc.twice(2), 4)' '  }' '}' >"$suite"
	printf '%s\n' target/ .bsp/ .metals/ >>.gitignore
	git add -A
	git commit --quiet -m fixture

	sed -i 's/^version = .*/version = 0.0.1/' .scalafmt.conf
	scala_check 1 scalafmt
	[[ $output == *"version = ${version#scalafmt }"* ]]
	git restore .scalafmt.conf
	sed -i 's/ = n/  =  n/' "$src"
	scala_check 1 scalafmt
	git restore "$src"
	mkdir -p target/generated
	printf 'object  Generated{val x=1}\n' >target/generated/Generated.scala
	scala_check 0 scalafmt
	cp target/generated/Generated.scala 'New file.scala'
	scala_check 1 scalafmt
	[[ $output == *"New file.scala"* ]]
	rm 'New file.scala'

	sed -i '/object Calc {/a\  var counter: Int = 0' "$src"
	scala_check 1 scala-compile
	[[ $output == *wartremover* ]]
	git restore "$src"
	sed -i '1i import scala.collection.mutable.ArrayBuffer' "$src"
	scala_check 1 scala-compile
	[[ $output == *"unused import"* ]]
	git restore "$src"
	scala_check 0 scala-compile

	sed -i '/class CalcSuite.*{/a\  final val label = "fixture"' "$suite"
	scala_check 1 scalafix
	[[ $output == *DisableSyntax* ]]
	git restore "$suite"
	scala_check 0 scalafix

	scala_check 0 scala-test
	report=.git/assay/scala-cobertura.xml
	grep -F 'filename="src/main/scala/Calc.scala"' "$report"
	grep -F 'hits="1"' "$report"
	cp "$report" "$T/before"
	scala_check 0 scala-test
	cmp "$T/before" "$report"
	devenv shell -- sbt --server --batch clean
	scala_check 0 scala-test
	cmp "$T/before" "$report"
	sed -i '/object Calc {/a\  def triple(n: Int): Int = n * 3' "$src"
	scala_check 1 scala-test
	[[ $output == *"new code: 0 of 1 lines covered, 0%, under 80%"* ]]
	sed -i '/assertEquals/a\    assertEquals(Calc.triple(2), 6)' "$suite"
	scala_check 0 scala-test
}
