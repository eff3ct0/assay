"""Machine-level collection for configured Grove owners."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import sqlite3
import sys

from hits import import_hits
from repository import collect_repo


def checkouts(root, owners):
    for owner in sorted(set(owners)):
        folder = root / owner
        if folder.is_symlink() or not folder.is_dir():
            continue
        for path in sorted(folder.iterdir()):
            if path.name.endswith(".wt") or path.is_symlink() or not (path / ".git").is_dir():
                continue
            yield path, owner + "/" + path.name


def main():
    parser = argparse.ArgumentParser(prog="assay collect")
    parser.add_argument("--db", required=True, type=Path)
    args = parser.parse_args()
    root = Path(os.environ.get("ASSAY_COLLECT_ROOT", "~/git")).expanduser().resolve()
    owners = json.loads(os.environ["ASSAY_COLLECT_OWNERS"])
    if not isinstance(owners, list) or not all(isinstance(n, str) and re.fullmatch(r"[\w.-]+", n)
                                                and n not in (".", "..") for n in owners):
        raise ValueError("ASSAY_COLLECT_OWNERS must be a JSON list of owner names")
    schema = Path(os.environ["ASSAY_SCHEMA"])
    measure_schema = json.loads((schema / "measure.json").read_bytes())
    repos = {}
    errors = False
    with Path(str(args.db) + ".lock").open("a") as lock, sqlite3.connect(args.db) as db:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        db.executescript((schema / "collect.sql").read_text())
        if os.environ.get("ASSAY_RULES"):
            rules = json.loads(Path(os.environ["ASSAY_RULES"]).read_bytes())["rules"]
            with db:
                db.execute("DELETE FROM rules")
                db.executemany("INSERT INTO rules VALUES (?)", ((r["name"],) for r in rules))
        for path, repo in checkouts(root, owners):
            repos[str(path)] = repo
            try:
                collect_repo(db, path, repo, measure_schema)
            except (OSError, ValueError) as err:
                print(f"assay: {repo}: {err}", file=sys.stderr)
                errors = True
        if os.environ.get("ASSAY_HITS_LOG"):
            import_hits(db, Path(os.environ["ASSAY_HITS_LOG"]), repos)
    return int(errors)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, KeyError, ValueError, sqlite3.Error) as exc:
        sys.exit(f"assay: {exc}")
