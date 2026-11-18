bats_require_minimum_version 1.5.0
load helpers

# gitleaks: gitleaks over the files git sees in the working tree, tracked or untracked but not ignored; history is not
# scanned.

# A GitHub token gitleaks's github-pat rule matches, put together here so that this file holds none.
token() { printf '%s%s' ghp_ aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5; }

# plant <file>: a line holding the token, in <file>.
plant() {
  mkdir -p "$(dirname "$1")"
  echo "url = \"https://x:$(token)@example.com\"" >"$1"
}

@test "a secret planted in a tracked or an untracked file fails, redacted, naming its place and fingerprint" {
  local_repo
  plant tracked.txt
  git add tracked.txt
  git commit --quiet -m tracked
  plant sub/untracked.txt
  run --separate-stderr "$assay" builtin gitleaks
  echo "$output"
  [ "$status" -eq 1 ]
  expected="sub/untracked.txt:1: github-pat (fingerprint sub/untracked.txt:github-pat:1)
tracked.txt:1: github-pat (fingerprint tracked.txt:github-pat:1)
gitleaks found 2 secrets in the working tree: remove each one, and rotate it if it ever left this machine; a false positive's fingerprint goes in .gitleaksignore."
  [ "$output" = "$expected" ]
  [[ $output != *"$(token)"* ]]
  [[ $stderr != *"$(token)"* ]]
}

@test "ignored files are not scanned: a local .env, .devenv/" {
  local_repo
  printf '%s\n' .env .devenv/ >.gitignore
  plant .env
  plant .devenv/state/x.txt
  run --separate-stderr "$assay" builtin gitleaks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "history is not scanned: a secret removed from the tree passes" {
  local_repo
  plant leaked.txt
  git add leaked.txt
  git commit --quiet -m leak
  git rm --quiet leaked.txt
  git commit --quiet -m "remove it"
  run --separate-stderr "$assay" builtin gitleaks
  [ "$status" -eq 0 ]
}

@test "a fingerprint in .gitleaksignore and the repo's .gitleaks.toml work as from the repo root" {
  local_repo
  plant fixture.txt
  echo 'fixture.txt:github-pat:1' >.gitleaksignore
  run --separate-stderr "$assay" builtin gitleaks
  [ "$status" -eq 0 ]
  rm .gitleaksignore
  cat >.gitleaks.toml <<'EOF'
[extend]
useDefault = true

[[allowlists]]
paths = ['''^fixture\.txt$''']
EOF
  run --separate-stderr "$assay" builtin gitleaks
  echo "$output $stderr"
  [ "$status" -eq 0 ]
}

@test "the scan leaves nothing behind, and a deleted tracked file or a symlink does not stop it" {
  local_repo
  echo x >gone.txt
  git add gone.txt
  git commit --quiet -m gone
  rm gone.txt
  ln -s a.txt link.txt
  mkdir -p nested
  git -C nested init --quiet
  run --separate-stderr "$assay" builtin gitleaks
  echo "$stderr"
  [ "$status" -eq 0 ]
  [ -z "$(ls "$(git rev-parse --absolute-git-dir)/assay")" ]
}

@test "without gitleaks on the PATH the check exits 127" {
  local_repo
  check gitleaks "\"$assay\" builtin gitleaks"
  # Only the tools assay check itself needs.
  mkdir "$T/bin"
  for t in bash git jq head tail wc mkdir rm; do ln -s "$(command -v "$t")" "$T/bin/$t"; done
  PATH=$T/bin run "$assay" check
  [ "$status" -eq 1 ]
  [[ ${lines[1]} == "FAIL gitleaks "*"(exit 127: tool not found)" ]]
}

@test "where hard links fail (another file system), gitleaks scans a plain copy" {
  local_repo
  plant tracked.txt
  # A cp that refuses hard links, as across file systems.
  mkdir "$T/bin"
  printf '%s\n' "#!$BASH" 'for a; do [ "$a" != --link ] || exit 1; done' "exec $(command -v cp) \"\$@\"" \
    >"$T/bin/cp"
  chmod +x "$T/bin/cp"
  PATH=$T/bin:$PATH run --separate-stderr "$assay" builtin gitleaks
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "tracked.txt:1: github-pat (fingerprint tracked.txt:github-pat:1)" ]
}

@test "gitleaks failing on its own (a broken .gitleaks.toml) is exit 2, not a finding" {
  local_repo
  echo 'this is = not [toml' >.gitleaks.toml
  run --separate-stderr "$assay" builtin gitleaks
  echo "$output $stderr"
  [ "$status" -eq 2 ]
  [[ $stderr == *$'\nassay: gitleaks failed (exit '* ]]
}
