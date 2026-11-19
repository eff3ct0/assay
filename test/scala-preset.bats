bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

@test "Scala merges a rendered scalafmt base and destination, preserving the project's settings" {
	local_repo
	languages scala
	mkdir "$T/bin"
	printf '%s\n' "#!${BASH:?}" 'echo "scalafmt 3.11.5"' >"$T/bin/scalafmt"
	chmod +x "$T/bin/scalafmt"
	export PATH=$T/bin:$PATH assay_presets=$T/presets
	cp -r "$BATS_TEST_DIRNAME/../preset" "$assay_presets"
	run "$assay" preset
	[ "$status" -eq 0 ]
	[ ! -e .assay-preset.json ]
	touch build.sbt
	"$assay" preset
	grep -Fx 'version = 3.11.5' .scalafmt.conf
	printf '\nmaxColumn = 120\n' >>.scalafmt.conf
	cp -r "$assay_presets/scala/1" "$assay_presets/scala/2"
	sed -i '1i # revised' "$assay_presets/scala/2/.scalafmt.conf"
	"$assay" preset
	holds .scalafmt.conf '# revised' 'version = 3.11.5' 'runner.dialect = scala3' '' 'maxColumn = 120'
	jq -e '.scala == 2' .assay-preset.json
}
