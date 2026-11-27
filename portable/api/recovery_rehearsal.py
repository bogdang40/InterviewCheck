"""Check recovered InterviewCheck database snapshots and vault keys offline."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import stat

from . import secret_box
from .recovery_snapshot import verify_snapshot


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        # argparse may include an unrecognized argument verbatim. A mistyped
        # secret must not be copied to a terminal log.
        self.exit(2, "Invalid arguments. Use --help for the command syntax.\n")


def _key_file(path: Path) -> bytes:
    # Verify the same open file we actually read. O_NONBLOCK avoids waiting on
    # a supplied pipe before we can reject it as a nonregular key source.
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_BINARY", 0))
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or (os.name != "nt" and info.st_mode & 0o077):
            raise secret_box.SecretBoxError("Invalid recovery key file.")
        raw = source.read(4097)
        if len(raw) > 4096:
            raise secret_box.SecretBoxError("Invalid recovery key file.")
        return secret_box.parse_key_file(raw)


def _load_keys(files: list[Path], names: list[str]):
    values: list[str | bytes] = [_key_file(path) for path in files]
    for name in names:
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            raise secret_box.SecretBoxError("Invalid key variable name.")
        value = os.environ.get(name, "").strip()
        if not value:
            raise secret_box.SecretBoxError("Missing recovery key variable.")
        values.append(value)
    return secret_box.supplied_keyring(values)


def rehearse(review_db: Path, access_db: Path, key_files: list[Path], key_env: list[str],
             expected_digests: dict[str, str] | None = None) -> dict:
    report = {"version": 1, "checked_at": datetime.now(timezone.utc).isoformat(), "status": "failed",
              "pair_check": "not_requested" if expected_digests is None else "unverified",
              "databases": {"review": {"status": "not_checked"}, "access": {"status": "not_checked"}}}
    try:
        keys = _load_keys(key_files, key_env)
        if not keys:
            raise secret_box.SecretBoxError("Missing recovery keys.")
    except (OSError, secret_box.SecretBoxError, UnicodeError, ValueError):
        report["error"] = "key_source_unavailable"
        return report
    try:
        if review_db.samefile(access_db):
            report["error"] = "same_snapshot"
            return report
    except OSError:
        pass  # The independent snapshot checks report each unreadable input.
    if expected_digests is not None and (
        set(expected_digests) != {"review", "access"}
        or any(not re.fullmatch(r"[0-9A-Fa-f]{64}", digest) for digest in expected_digests.values())
    ):
        report["error"] = "invalid_expected_digests"
        return report
    for kind, path in (("review", review_db), ("access", access_db)):
        digest = expected_digests[kind].lower() if expected_digests else None
        report["databases"][kind] = verify_snapshot(path, kind, keys, digest)
    results = report["databases"].values()
    if expected_digests is not None and all(item.get("digest_matched") for item in results):
        report["pair_check"] = "matched"
    if all(item["status"] == "checked" for item in results):
        count = sum(table["verified"] for item in results for table in item["tables"].values())
        report["status"] = "verified" if count else "no_encrypted_records"
    return report


def main(argv=None) -> int:
    parser = _Parser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--review-db", type=Path, required=True, help="Extracted review.sqlite3 snapshot")
    parser.add_argument("--access-db", type=Path, required=True, help="Extracted access.sqlite3 snapshot")
    parser.add_argument("--key-file", type=Path, action="append", default=[], help="Recovered file key (repeatable)")
    parser.add_argument("--key-env", action="append", default=[], help="Name of a variable holding a recovered environment key (repeatable)")
    parser.add_argument("--review-sha256", help="Review database SHA256 from a trusted backup inventory")
    parser.add_argument("--access-sha256", help="Access database SHA256 from the same inventory")
    parser.add_argument("--json", action="store_true", help="Write a machine readable report")
    args = parser.parse_args(argv)
    if not (args.key_file or args.key_env):
        parser.error("Supply at least one key source.")
    expected = None
    if args.review_sha256 is not None or args.access_sha256 is not None:
        expected = {"review": args.review_sha256, "access": args.access_sha256}
        if any(not digest or not re.fullmatch(r"[0-9A-Fa-f]{64}", digest) for digest in expected.values()):
            parser.error("Supply both SHA256 digests.")
    report = rehearse(args.review_db, args.access_db, args.key_file, args.key_env, expected)
    if args.json:
        print(json.dumps(report, sort_keys=True))
    else:
        print(f"Recovery rehearsal: {report['status']}")
        print(f"Snapshot pair comparison with trusted inventory: {report['pair_check']}")
        if "error" in report:
            print(report["error"])
        for kind, result in report["databases"].items():
            print(f"{kind}: {result['status']}")
            for table, counts in result.get("tables", {}).items():
                print(f"  {table}: {counts['verified']} of {counts['encrypted']} verified")
                if counts.get("missing_required"):
                    print(f"    Required credentials absent: {counts['missing_required']}")
    return {"verified": 0, "failed": 1, "no_encrypted_records": 3}[report["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
