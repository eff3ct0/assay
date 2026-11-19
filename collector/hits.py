"""Import a bounded prefix of an append-only JSONL file, without touching writers."""

import json
import os


def complete_lines(stream, end):
    while stream.tell() < end:
        line = stream.readline(end - stream.tell())
        if not line.endswith(b"\n"):
            break
        yield line


def import_hits(db, log, repos):
    try:
        stream = log.open("rb")
    except FileNotFoundError:
        return
    with stream, db:
        path = str(log.absolute())
        stat = os.fstat(stream.fileno())
        row = db.execute("SELECT device,inode,position FROM hit_cursors WHERE path=?", (path,)).fetchone()
        position = 0
        if row:
            device, inode, position = row
            if (device, inode) != (stat.st_dev, stat.st_ino) or position > stat.st_size:
                raise ValueError(f"append-only hits file replaced or shortened: {path}")
        stream.seek(position)
        for line in complete_lines(stream, stat.st_size):
            event = json.loads(line)
            if event["v"] != 1:
                raise ValueError("unknown hits log version")
            if event["repo"] in repos:
                db.execute("INSERT INTO hits VALUES (?,?)", (repos[event["repo"]], line.decode().strip()))
            position = stream.tell()
        db.execute("INSERT OR REPLACE INTO hit_cursors VALUES (?,?,?,?)",
                   (path, stat.st_dev, stat.st_ino, position))
