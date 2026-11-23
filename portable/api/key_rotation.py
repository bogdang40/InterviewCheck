"""Command line entry point for re-encrypting every stored secret with the active key."""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import sys

from . import secret_box, store
from .error_sanitizer import sanitize_error_text
from .secret_rotation import PartialRotationError, RotationReport, key_status, rotate_database_secrets

__all__ = ("PartialRotationError", "RotationReport", "key_status", "main", "rotate_database_secrets")


def _resolve_old_key_env(arg: str) -> str:
    cleaned = arg.strip()
    if not cleaned:
        raise secret_box.SecretBoxError("Old key argument cannot be empty.")
    if cleaned in os.environ:
        val = os.environ[cleaned].strip()
        if not val:
            raise secret_box.SecretBoxError(f"Environment variable {cleaned} is empty.")
        return val
    if cleaned.isidentifier():
        raise secret_box.SecretBoxError(f"Environment variable {cleaned} is not set.")
    return cleaned


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m api.key_rotation",
        description="Re-encrypt stored model keys, alert signing secrets and TOTP secrets with the active secret key.",
    )
    parser.add_argument("--db", type=Path, default=None, help="Path to review.sqlite3 database.")
    parser.add_argument(
        "--old-key-env",
        action="append",
        default=[],
        help="Environment variable name holding a retired master key (repeatable).",
    )
    parser.add_argument("--old-key-file", action="append", default=[], type=Path, help="Retired .model_secret.key file path (repeatable).")
    parser.add_argument("--rotate-file-key", action="store_true", help="Generate a new 0600 file key and re-encrypt all stored secrets.")
    parser.add_argument("--dry-run", action="store_true", help="Verify all stored secrets without modifying the databases or key file.")
    parser.add_argument("--json", action="store_true", dest="as_json", help="Print the rotation report as JSON.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    prev_db_env = os.environ.get("INTERVIEWCHECK_DB")
    db_file = args.db if args.db is not None else store.db_path()
    if args.db is not None:
        os.environ["INTERVIEWCHECK_DB"] = str(db_file)
    try:
        if not db_file.is_file():
            print("Database file does not exist.", file=sys.stderr)
            return 1
        old_env_keys = [_resolve_old_key_env(item) for item in args.old_key_env]
        old_file_keys = [secret_box.load_key_file(path) for path in args.old_key_file]
        previous_keys: list[str | bytes] = [*old_env_keys, *old_file_keys]
        with closing(sqlite3.connect(db_file, timeout=10)) as db:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA foreign_keys=ON")
            report = rotate_database_secrets(
                db,
                previous_keys=previous_keys,
                rotate_file_key=args.rotate_file_key,
                dry_run=args.dry_run,
            )
    except (secret_box.SecretBoxError, sqlite3.Error, OSError) as exc:
        print(sanitize_error_text(str(exc), "Key rotation failed."), file=sys.stderr)
        return 1
    finally:
        if args.db is not None:
            if prev_db_env is None:
                os.environ.pop("INTERVIEWCHECK_DB", None)
            else:
                os.environ["INTERVIEWCHECK_DB"] = prev_db_env

    payload = report.to_dict()
    if args.as_json:
        print(json.dumps(payload))
    else:
        mode = "DRY RUN" if report.dry_run else "ROTATED"
        print(
            f"[{mode}] active_key_id={report.active_key_id} source={report.key_source} "
            f"total={report.total_with_keys} rotated={report.rotated_count} "
            f"already_current={report.already_current_count} rotated_file_key={report.rotated_file_key}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
