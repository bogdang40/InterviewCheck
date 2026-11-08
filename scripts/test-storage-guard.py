#!/usr/bin/env python3
"""Detect writes to live app storage during XCTest without reading it into logs."""

import hashlib
import json
from pathlib import Path
import sys


def fingerprint():
    home = Path.home()
    roots = [home / "Library/Application Support/InterviewCheck",
             home / ".interviewcheck/cache/tool-outputs",
             home / "Documents/InterviewCheck Roles",
             home / "Library/Logs/InterviewCheck"]
    paths = {path for root in roots if root.exists() for path in root.rglob("*")}
    paths.update([home / "Library/Preferences/com.interviewcheck.app.plist",
                  home / ".interviewcheck/owner.license"])
    result = {}
    for path in sorted(paths):
        # SQLite shared memory holds reader locks, not persistent app data.
        if not path.is_file() or path.name.endswith("-shm"):
            continue
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        result[str(path.relative_to(home))] = digest.hexdigest()
    return result


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("snapshot", "verify"):
        raise SystemExit("Usage: test-storage-guard.py snapshot|verify SNAPSHOT_PATH")
    mode, snapshot_path = sys.argv[1], Path(sys.argv[2])
    current = fingerprint()
    if mode == "snapshot":
        snapshot_path.write_text(json.dumps(current, indent=2) + "\n")
        return
    previous = json.loads(snapshot_path.read_text())
    changed = [key for key in sorted(previous.keys() | current.keys())
               if previous.get(key) != current.get(key)]
    if changed:
        print("ERROR: Live app storage changed during tests:", file=sys.stderr)
        for key in changed:
            print(f"  {key}", file=sys.stderr)
        print("Concurrent use of the live app can also trigger this guard.", file=sys.stderr)
        raise SystemExit(1)
    print(f"Storage guard passed: {len(current)} live files unchanged.")


if __name__ == "__main__":
    main()
