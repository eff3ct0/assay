# The Python tools test/defaults.bats uses to exercise assay-pytest without a project venv.
{ python3 }:
python3.withPackages (ps: [
  ps.coverage
  ps.hypothesis
  ps.pytest
])
