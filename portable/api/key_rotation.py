"""Atomic database and file key rotation helpers plus CLI for model credentials."""
import argparse
import base64
from collections.abc import Iterable
from contextlib import closing
from dataclasses import dataclass
import json
import os
from pathlib import Path
import secrets
import sqlite3
import sys
from typing import Any

from . import secret_box, store
from .error_sanitizer import sanitize_error_text


@dataclass(frozen=True)
class RotationReport:
    active_key_id: str
    key_source: str
    total_with_keys: int
    rotated_count: int
    already_current_count: int
    dry_run: bool
    rotated_file_key: bool
    previous_active_key_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "active_key_id": self.active_key_id,
            "previous_active_key_id": self.previous_active_key_id,
            "key_source": self.key_source,
            "total_with_keys": self.total_with_keys,
            "rotated_count": self.rotated_count,
            "already_current_count": self.already_current_count,
            "dry_run": self.dry_run,
            "rotated_file_key": self.rotated_file_key,
        }


def key_status(db: sqlite3.Connection) -> dict[str, Any]:
    active_kid = secret_box.active_key_id()
    source = secret_box.key_source()
    prev_count = secret_box.previous_key_count()
    rows = db.execute(
        "SELECT encrypted_api_key FROM connected_models WHERE encrypted_api_key IS NOT NULL AND encrypted_api_key != ''"
    ).fetchall()
    current_v2_count = 0
    needs_rotation_count = 0
    for row in rows:
        token = row[0]
        try:
            version, kid = secret_box.token_key_info(token)
        except secret_box.SecretBoxError:
            needs_rotation_count += 1
            continue
        if version == "v2" and kid == active_kid:
            current_v2_count += 1
        else:
            needs_rotation_count += 1
    return {
        "active_key_id": active_kid,
        "key_source": source,
        "previous_keys_configured": prev_count,
        "total_with_keys": len(rows),
        "current_v2_count": current_v2_count,
        "needs_rotation_count": needs_rotation_count,
    }


def _write_key_file(dest: Path, encoded: bytes) -> Path:
    dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, encoded)
        os.fsync(fd)
    finally:
        os.close(fd)
    if os.name != "nt":
        os.chmod(dest, 0o600)
    return dest


def _write_temp_key_file(key_path: Path, master: bytes) -> Path:
    return _write_key_file(key_path.with_name(key_path.name + ".tmp"), base64.urlsafe_b64encode(master))


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


def rotate_database_secrets(
    db: sqlite3.Connection,
    *,
    previous_keys: Iterable[str | bytes] = (),
    rotate_file_key: bool = False,
    dry_run: bool = False,
) -> RotationReport:
    was_in_tx = db.in_transaction
    if rotate_file_key and was_in_tx:
        raise secret_box.SecretBoxError("Cannot rotate key file inside an active caller transaction.")

    source = secret_box.key_source()
    extra_previous = tuple(previous_keys)
    key_path: Path | None = None
    previous_kid: str | None = None
    if rotate_file_key:
        if source != "file":
            raise secret_box.SecretBoxError(
                "Cannot rotate file key while INTERVIEWCHECK_MODEL_SECRET_KEY is configured."
            )
        key_path = secret_box._key_file_path()
        old_master = secret_box._load_or_create_file_key(key_path)
        previous_kid = secret_box.key_id_for(old_master)
        target_master = secrets.token_bytes(32)
        decrypt_previous: tuple[str | bytes, ...] = (*extra_previous, old_master)
    else:
        target_master = secret_box._master_key()
        decrypt_previous = extra_previous
    target_kid = secret_box.key_id_for(target_master)

    if not was_in_tx:
        db.execute("BEGIN IMMEDIATE")
    else:
        db.execute("SAVEPOINT ic_key_rotation")

    tmp_path: Path | None = None
    bak_path: Path | None = None
    replaced = False
    try:
        rows = db.execute(
            "SELECT id, encrypted_api_key FROM connected_models "
            "WHERE encrypted_api_key IS NOT NULL AND encrypted_api_key != '' ORDER BY id"
        ).fetchall()
        updates: list[tuple[str, str]] = []
        already_current = 0
        for row in rows:
            row_id, ciphertext = row[0], row[1]
            version, row_kid = secret_box.token_key_info(ciphertext)
            plaintext = secret_box.decrypt_secret(ciphertext, aad=row_id, previous_keys=decrypt_previous)
            if not rotate_file_key and version == "v2" and row_kid == target_kid:
                already_current += 1
                continue
            new_cipher = secret_box.encrypt_with_master(plaintext, target_master, aad=row_id, envelope="v2")
            updates.append((new_cipher, row_id))

        if not dry_run:
            now = store.timestamp()
            for new_cipher, row_id in updates:
                db.execute(
                    "UPDATE connected_models SET encrypted_api_key=?, updated_at=? WHERE id=?",
                    (new_cipher, now, row_id),
                )
            if rotate_file_key and key_path is not None:
                tmp_path = _write_temp_key_file(key_path, target_master)
                if key_path.exists():
                    bak_path = _write_key_file(key_path.with_name(key_path.name + ".bak"), key_path.read_bytes())
                os.replace(tmp_path, key_path)
                replaced = True
                tmp_path = None

        if not was_in_tx:
            db.commit()
        else:
            db.execute("RELEASE SAVEPOINT ic_key_rotation")
        if bak_path is not None:
            bak_path.unlink(missing_ok=True)
            bak_path = None
    except Exception:
        if replaced and bak_path is not None and key_path is not None and bak_path.exists():
            os.replace(bak_path, key_path)
        else:
            if tmp_path is not None:
                tmp_path.unlink(missing_ok=True)
            if bak_path is not None:
                bak_path.unlink(missing_ok=True)
        if not was_in_tx:
            if db.in_transaction:
                db.rollback()
        else:
            db.execute("ROLLBACK TO SAVEPOINT ic_key_rotation")
            db.execute("RELEASE SAVEPOINT ic_key_rotation")
        raise

    return RotationReport(
        active_key_id=target_kid,
        previous_active_key_id=previous_kid,
        key_source=source,
        total_with_keys=len(rows),
        rotated_count=len(updates),
        already_current_count=already_current,
        dry_run=dry_run,
        rotated_file_key=bool(rotate_file_key and not dry_run),
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m api.key_rotation",
        description="Atomically re-encrypt stored model credentials with the active secret key.",
    )
    parser.add_argument("--db", type=Path, default=None, help="Path to review.sqlite3 database.")
    parser.add_argument(
        "--old-key-env",
        action="append",
        default=[],
        help="Environment variable name holding a retired master key (repeatable).",
    )
    parser.add_argument("--old-key-file", action="append", default=[], type=Path, help="Retired .model_secret.key file path (repeatable).")
    parser.add_argument("--rotate-file-key", action="store_true", help="Generate a new 0600 file key and re-encrypt all model credentials.")
    parser.add_argument("--dry-run", action="store_true", help="Verify all credentials without modifying the database or key file.")
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
