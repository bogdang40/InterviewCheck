"""Per table rotators for every column encrypted with the model secret master key."""
from collections.abc import Iterable
from dataclasses import dataclass, field
import sqlite3
from typing import Protocol

from . import secret_box, store


@dataclass(frozen=True)
class RotationKeys:
    target_master: bytes
    target_kid: str
    decrypt_previous: tuple[str | bytes, ...]
    rotate_all: bool


@dataclass(frozen=True)
class ColumnStatus:
    total_with_keys: int = 0
    current_v2_count: int = 0
    needs_rotation_count: int = 0

    def to_dict(self) -> dict[str, int]:
        return {"total_with_keys": self.total_with_keys, "current_v2_count": self.current_v2_count,
                "needs_rotation_count": self.needs_rotation_count}


@dataclass
class ColumnPlan:
    column: "EncryptedColumn"
    total_with_keys: int = 0
    already_current_count: int = 0
    updates: list[tuple[str, str]] = field(default_factory=list)

    def apply(self, db: sqlite3.Connection) -> None:
        self.column.write(db, self.updates)

    def to_dict(self) -> dict[str, int]:
        return {"total_with_keys": self.total_with_keys, "rotated_count": len(self.updates),
                "already_current_count": self.already_current_count}


class SecretTable(Protocol):
    name: str

    def status(self, db: sqlite3.Connection, active_kid: str) -> ColumnStatus: ...

    def plan(self, db: sqlite3.Connection, keys: RotationKeys) -> ColumnPlan: ...


@dataclass(frozen=True)
class EncryptedColumn:
    """One ciphertext column whose envelope AAD is the row's key column."""

    table: str
    column: str
    aad_column: str
    touch_column: str | None = None

    @property
    def name(self) -> str:
        return self.table

    def _present(self, db: sqlite3.Connection) -> bool:
        return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (self.table,)).fetchone() is not None

    def tokens(self, db: sqlite3.Connection) -> list[tuple[str, str]]:
        if not self._present(db):
            return []
        rows = db.execute(
            f"SELECT {self.aad_column}, {self.column} FROM {self.table} "
            f"WHERE {self.column} IS NOT NULL AND {self.column} != '' ORDER BY {self.aad_column}"
        )
        return [(row[0], row[1]) for row in rows.fetchall()]

    def status(self, db: sqlite3.Connection, active_kid: str) -> ColumnStatus:
        tokens = self.tokens(db)
        current = 0
        for _, token in tokens:
            try:
                current += secret_box.token_key_info(token) == ("v2", active_kid)
            except secret_box.SecretBoxError:
                continue
        return ColumnStatus(len(tokens), current, len(tokens) - current)

    def plan(self, db: sqlite3.Connection, keys: RotationKeys) -> ColumnPlan:
        """Decrypt every row first, so one unreadable row aborts before anything is written."""
        plan = ColumnPlan(self)
        for row_id, token in self.tokens(db):
            plan.total_with_keys += 1
            plaintext = secret_box.decrypt_secret(token, aad=row_id, previous_keys=keys.decrypt_previous)
            if not keys.rotate_all and secret_box.token_key_info(token) == ("v2", keys.target_kid):
                plan.already_current_count += 1
                continue
            plan.updates.append(
                (secret_box.encrypt_with_master(plaintext, keys.target_master, aad=row_id, envelope="v2"), row_id)
            )
        return plan

    def write(self, db: sqlite3.Connection, updates: Iterable[tuple[str, str]]) -> None:
        if self.touch_column is None:
            sql, extra = f"UPDATE {self.table} SET {self.column}=? WHERE {self.aad_column}=?", ()
        else:
            sql, extra = f"UPDATE {self.table} SET {self.column}=?, {self.touch_column}=? WHERE {self.aad_column}=?", (store.timestamp(),)
        for cipher, row_id in updates:
            db.execute(sql, (cipher, *extra, row_id))


MODEL_API_KEYS = EncryptedColumn("connected_models", "encrypted_api_key", "id", touch_column="updated_at")
ALERT_SIGNING_SECRETS = EncryptedColumn("alert_rules", "encrypted_signing_secret", "id")
TOTP_SECRETS = EncryptedColumn("user_totp", "secret_enc", "user_id")

REVIEW_TABLES: tuple[SecretTable, ...] = (MODEL_API_KEYS, ALERT_SIGNING_SECRETS)
ACCESS_TABLES: tuple[SecretTable, ...] = (TOTP_SECRETS,)
