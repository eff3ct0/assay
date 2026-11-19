# Assertions shared by the CLI's tests (test/helpers.bash) and the devenv tests (test/devenv/helpers.bash).

# output_is <line>...: bats' $output is these lines.
output_is() {
	local expected
	expected=$(printf '%s\n' "$@")
	[ "${output?}" = "$expected" ]
}

# holds <file> <line>...: the file holds these lines.
holds() {
	local file=$1 expected actual
	shift
	expected=$(printf '%s\n' "$@")
	actual=$(cat "$file")
	[ "$actual" = "$expected" ]
}
