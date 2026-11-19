"""Rotate the shared hits log and import closed batches transactionally."""

import fcntl
import json
from pathlib import Path
import uuid


def import_batch(db, batch, repos):
    with batch.open() as lines:
        for line in lines:
            event = json.loads(line)
            if event["v"] != 1:
                raise ValueError("unknown hits log version")
            if event["repo"] in repos:
                db.execute("INSERT INTO hits VALUES (?,?)", (repos[event["repo"]], line.strip()))


def import_hits(db, log, repos):
    if not log.parent.is_dir():
        return
    # Hold the writers' lock only for the rename. The unique batch receipt is
    # committed with its rows: a crash before unlinking never replays them.
    prefix = log.name + ".pending-"
    with Path(str(log) + ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if log.exists():
            log.rename(log.with_name(prefix + uuid.uuid4().hex))
    for batch in log.parent.iterdir():
        if not batch.name.startswith(prefix):
            continue
        with db:
            if db.execute("INSERT OR IGNORE INTO batches VALUES (?)", (batch.name,)).rowcount:
                import_batch(db, batch, repos)
        batch.unlink()
