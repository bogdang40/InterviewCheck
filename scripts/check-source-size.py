#!/usr/bin/env python3
"""Enforce the first party source size limit without changing vendor code."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOTS = ("InterviewCheck", "InterviewCheckTests", "server/src", "server/test", "scripts")
EXTENSIONS = {".swift", ".ts", ".js", ".mjs", ".py", ".sh", ".metal", ".html", ".css"}
VENDOR_FILES: set = set()


def main():
    checked = 0
    violations = []
    for directory in SOURCE_ROOTS:
        for path in sorted((ROOT / directory).rglob("*")):
            relative = path.relative_to(ROOT).as_posix()
            if not path.is_file() or path.suffix not in EXTENSIONS or relative in VENDOR_FILES:
                continue
            count = len(path.read_text().splitlines())
            checked += 1
            if count > 400:
                violations.append(f"{relative}: {count} lines")
    if violations:
        print("Source files exceed 400 lines:\n" + "\n".join(violations), file=sys.stderr)
        return 1
    print(f"Source size check passed: {checked} first party files, all at most 400 lines.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
