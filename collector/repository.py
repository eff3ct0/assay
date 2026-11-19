"""Rebuild one repository's history and measure its default tip."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

import jsonschema


def command(args, cwd, deadline, **kwargs):
    with subprocess.Popen(args, cwd=cwd, start_new_session=True,
                          stdout=kwargs.pop("stdout", subprocess.PIPE), **kwargs) as proc:
        try:
            data, _ = proc.communicate(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise ValueError(f"{args[0]} exceeded the repository timeout")
        if proc.returncode:
            raise ValueError(f"{args[0]} {args[1]} exited {proc.returncode}")
        return data


revert = re.compile(rb'^Revert "|This reverts commit [a-fA-F0-9]{7,64}\b')
pr = re.compile(rb'\(#[0-9]+\)$|^Merge pull request #[0-9]+\b')


def history(git, tip):
    records = git("log", "--first-parent", "-z", "--format=%H%x00%P%x00%ct%x00%an%x00%s%x00%B", tip)
    fields = iter(records.removesuffix(b"\0").split(b"\0"))
    for sha, parents, timestamp, author, subject, message in zip(*[fields] * 6):
        if author.endswith(b"[bot]"):
            continue
        reverted = bool(revert.search(message))
        parents = parents.decode().split()
        if len(parents) > 1 and not reverted:
            merged = git("log", "-z", "--format=%B", *parents[1:], "^" + parents[0])
            reverted = any(revert.search(m) for m in merged.split(b"\0"))
        yield sha.decode(), int(timestamp), bool(pr.search(subject)), reverted


def snapshot(git, tip, deadline, schema):
    try:
        if not git("ls-tree", tip, "--", "devenv.nix"):
            return "unadopted", None, None, []
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryFile() as archive:
            tree = Path(tmp) / "tree"
            tree.mkdir()
            git("archive", "--format=tar", tip, stdout=archive)
            archive.seek(0)
            with tarfile.open(fileobj=archive) as tar:
                tar.extractall(tree, filter="data")
            if not (tree / "devenv.nix").is_file():
                return "unadopted", None, None, []
            marker = Path(tmp) / "config"
            env = {k: v for k, v in os.environ.items() if k not in ("ASSAY_CONFIG", "ASSAY_HITS_LOG")}
            # Distinguish a successfully entered but unadopted devenv from an evaluation failure.
            data = command(["devenv", "shell", "--", "sh", "-c",
                            'if [ -z "${ASSAY_CONFIG:-}" ]; then touch "$1.absent"; exit 0; fi; '
                            'cp "$ASSAY_CONFIG" "$1" && exec assay measure', "measure", str(marker)],
                           tree, deadline, env=env)
            if marker.with_suffix(".absent").exists():
                return "unadopted", None, None, []
            config = json.loads(marker.read_bytes())
            metrics = json.loads(data)
            jsonschema.validate(metrics, schema)
            return "ok", json.dumps(metrics), None, [
                n for n, c in config["checks"].items() if c.get("enable", True)]
    except (OSError, ValueError, KeyError, tarfile.TarError, jsonschema.ValidationError) as err:
        return "failed", None, str(err), []


def collect_repo(db, path, repo, schema):
    deadline = time.monotonic() + 1800

    def git(*args, **kwargs):
        return command(["git", *args], path, deadline, **kwargs)

    ref = "HEAD"
    if git("remote").strip():
        git("fetch", "--no-recurse-submodules", "origin")
        ref = "refs/remotes/origin/HEAD"
    tip = git("rev-parse", "--verify", ref + "^{commit}").decode().strip()
    changes = list(history(git, tip))
    previous = db.execute("SELECT tip FROM repos WHERE repo=?", (repo,)).fetchone()
    measured = snapshot(git, tip, deadline, schema) if previous != (tip,) else None
    with db:
        db.execute("DELETE FROM changes WHERE repo=?", (repo,))
        db.executemany("INSERT INTO changes VALUES (?,?,?,?,?)", ((repo, *c) for c in changes))
        if measured:
            state, metrics, error, names = measured
            db.execute("INSERT OR REPLACE INTO repos VALUES (?,?,?)", (repo, tip, state))
            if state != "unadopted":
                db.execute("INSERT INTO snapshots VALUES (?,?,unixepoch(),?,?)", (repo, tip, metrics, error))
            if state != "failed":
                db.execute("DELETE FROM checks WHERE repo=?", (repo,))
                db.executemany("INSERT INTO checks VALUES (?,?)", ((repo, n) for n in names))
            if error:
                print(f"assay: {repo}@{tip}: {error}", file=sys.stderr)
