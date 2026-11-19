bats_require_minimum_version 1.5.0
# shellcheck source=test/devenv/helpers.bash
source "${BATS_TEST_DIRNAME:?}/helpers.bash"

@test "uv sync waits for the Python directory's manifest, then runs and reports errors" {
	consumer "$ASSAY_BARE"
	mkdir 'python project'
	devenv_nix '{
	  assay.python.uv.syncIfManifest = true;
	  languages.python = {
	    enable = true;
	    directory = "python project";
	    venv.enable = true;
	    uv.enable = true;
	    uv.sync.enable = true;
	  };
	}'
	devenv test
	[ ! -e 'python project/pyproject.toml' ]
	[ ! -e 'python project/uv.lock' ]
	printf '%s\n' '[project]' 'name = "example"' 'version = "0.1.0"' >'python project/pyproject.toml'
	devenv test
	grep -q 'name = "example"' 'python project/uv.lock'
	echo 'not valid toml' >>'python project/pyproject.toml'
	run devenv test
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"uv sync failed"* ]]
}

@test "without the opt-in, an enabled sync still requires a manifest" {
	consumer "$ASSAY_BARE"
	devenv_nix '{ languages.python = { enable = true; uv.enable = true; uv.sync.enable = true; }; }'
	run devenv test
	echo "$output"
	[ "$status" -ne 0 ]
	[[ $output == *"No pyproject.toml found"* ]]
}
