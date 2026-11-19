bats_require_minimum_version 1.5.0
# shellcheck source=test/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

scala_v1() {
	local_repo
	languages scala
	mkdir "$T/bin"
	printf '%s\n' "#!${BASH:?}" "echo \"scalafmt \${FORMAT_VERSION:?}\"" >"$T/bin/scalafmt"
	chmod +x "$T/bin/scalafmt"
	export PATH=$T/bin:$PATH assay_presets=$T/presets FORMAT_VERSION=3.11.1
	cp -r "$BATS_TEST_DIRNAME/../preset" "$assay_presets"
	run "$assay" preset
	[ "$status" -eq 0 ]
	[ ! -e .assay-preset.json ]
	touch build.sbt
	"$assay" preset
	grep -Fx 'version = 3.11.1' .scalafmt.conf
}

upgrade() {
	export FORMAT_VERSION=3.11.5
	cp -r "$assay_presets/scala/1" "$assay_presets/scala/2"
	sed -i '1i # revised' "$assay_presets/scala/2/.scalafmt.conf"
	"$assay" preset
}

@test "an untouched Scala v1 merges when the preset and CLI change together" {
	scala_v1
	upgrade
	grep -Fx '# revised' .scalafmt.conf
	grep -Fx 'version = 3.11.5' .scalafmt.conf
	jq -e '.scala == 2' .assay-preset.json
}

@test "a joint upgrade preserves unrelated Scala config and flags a competing version edit" {
	scala_v1
	printf '\nmaxColumn = 120\n' >>.scalafmt.conf
	sed -i 's/^version = .*/version = 3.11.2/' .scalafmt.conf
	run upgrade
	[ "$status" -eq 1 ]
	grep -Fx '<<<<<<< .scalafmt.conf' .scalafmt.conf
	for v in 3.11.1 3.11.2 3.11.5; do grep -Fx "version = $v" .scalafmt.conf; done
	grep -Fx 'maxColumn = 120' .scalafmt.conf
}
