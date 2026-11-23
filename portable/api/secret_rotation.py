"""Re-encrypt every stored secret under the active master key and report what remains."""
from collections.abc import Iterable
from dataclasses import dataclass, field
import secrets
import sqlite3
from typing import Any

from . import secret_box
from .encrypted_columns import ACCESS_TABLES, REVIEW_TABLES, ColumnPlan, ColumnStatus, RotationKeys
from .key_file_swap import KeyFileSwap
from .rotation_access_db import open_access_database


class PartialRotationError(secret_box.SecretBoxError):
    """The account database committed under a new file key but the review database did not."""


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
    tables: dict[str, dict[str, int]] = field(default_factory=dict)

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
            "tables": self.tables,
        }


def key_status(db: sqlite3.Connection) -> dict[str, Any]:
    active_kid = secret_box.active_key_id()
    tables = {table.name: table.status(db, active_kid) for table in REVIEW_TABLES}
    with open_access_database(write=False) as access:
        for table in ACCESS_TABLES:
            tables[table.name] = table.status(access, active_kid) if access is not None else ColumnStatus()
    return {
        "active_key_id": active_kid,
        "key_source": secret_box.key_source(),
        "previous_keys_configured": secret_box.previous_key_count(),
        "total_with_keys": sum(s.total_with_keys for s in tables.values()),
        "current_v2_count": sum(s.current_v2_count for s in tables.values()),
        "needs_rotation_count": sum(s.needs_rotation_count for s in tables.values()),
        "tables": {name: s.to_dict() for name, s in tables.items()},
    }


class _ReviewTransaction:
    """Owns the review transaction, or a savepoint inside the caller's transaction."""

    def __init__(self, db: sqlite3.Connection):
        self.db, self.nested = db, db.in_transaction

    def begin(self) -> None:
        self.db.execute("SAVEPOINT ic_key_rotation" if self.nested else "BEGIN IMMEDIATE")

    def commit(self) -> None:
        if self.nested:
            self.db.execute("RELEASE SAVEPOINT ic_key_rotation")
        else:
            self.db.commit()

    def rollback(self) -> None:
        if self.nested:
            self.db.execute("ROLLBACK TO SAVEPOINT ic_key_rotation")
            self.db.execute("RELEASE SAVEPOINT ic_key_rotation")
        elif self.db.in_transaction:
            self.db.rollback()


def _resolve_keys(previous_keys: tuple, rotate_file_key: bool) -> tuple[RotationKeys, KeyFileSwap | None, str | None]:
    if not rotate_file_key:
        master = secret_box._master_key()
        return RotationKeys(master, secret_box.key_id_for(master), previous_keys, False), None, None
    if secret_box.key_source() != "file":
        raise secret_box.SecretBoxError("Cannot rotate file key while INTERVIEWCHECK_MODEL_SECRET_KEY is configured.")
    key_path = secret_box._key_file_path()
    old_master = secret_box._load_or_create_file_key(key_path)
    master = secrets.token_bytes(32)
    keys = RotationKeys(master, secret_box.key_id_for(master), (*previous_keys, old_master), True)
    return keys, KeyFileSwap(key_path), secret_box.key_id_for(old_master)


def _report(keys, plans: list[ColumnPlan], *, dry_run, swap, previous_kid) -> RotationReport:
    return RotationReport(
        active_key_id=keys.target_kid,
        previous_active_key_id=previous_kid,
        key_source=secret_box.key_source(),
        total_with_keys=sum(p.total_with_keys for p in plans),
        rotated_count=sum(len(p.updates) for p in plans),
        already_current_count=sum(p.already_current_count for p in plans),
        dry_run=dry_run,
        rotated_file_key=bool(swap is not None and not dry_run),
        tables={p.column.name: p.to_dict() for p in plans},
    )


def rotate_database_secrets(
    db: sqlite3.Connection,
    *,
    previous_keys: Iterable[str | bytes] = (),
    rotate_file_key: bool = False,
    dry_run: bool = False,
) -> RotationReport:
    """Rotate review database secrets in one transaction and account secrets in another.

    Every row in both databases is decrypted before either is written. Rows already
    under the target key are skipped, so a rerun after any partial failure finishes the job.
    """
    if rotate_file_key and db.in_transaction:
        raise secret_box.SecretBoxError("Cannot rotate key file inside an active caller transaction.")
    keys, swap, previous_kid = _resolve_keys(tuple(previous_keys), rotate_file_key)
    review = _ReviewTransaction(db)
    review.begin()
    access_committed = False
    try:
        with open_access_database(write=not dry_run) as access:
            plans = [table.plan(db, keys) for table in REVIEW_TABLES]
            access_plans = [table.plan(access, keys) for table in ACCESS_TABLES] if access is not None else []
            if not dry_run:
                for plan in plans:
                    plan.apply(db)
                for plan in access_plans:
                    plan.apply(access)
                if swap is not None:
                    swap.install(keys.target_master)
            if access is not None:
                access.commit()
                access_committed = not dry_run and any(plan.updates for plan in access_plans)
        review.commit()
    except Exception as exc:
        review.rollback()
        if swap is not None and access_committed:
            raise PartialRotationError(
                f"Account secrets now use the new key file, but the review database rotation failed. "
                f"Rerun key rotation with --old-key-file pointing to {swap.backup_path.name}."
            ) from exc
        if swap is not None:
            swap.restore()
        raise
    if swap is not None:
        swap.discard_backup()
    return _report(keys, [*plans, *access_plans], dry_run=dry_run, swap=swap, previous_kid=previous_kid)
