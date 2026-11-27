"""Workspace admission for model completions and embeddings, measured per UTC month."""
import asyncio
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import sqlite3
import threading

from anyio import CancelScope
from anyio.lowlevel import checkpoint_if_cancelled
from fastapi import HTTPException
from starlette.concurrency import run_in_threadpool

from . import sql_script, ssrf_guard, store

MAX_MONTHLY_LIMIT = 1_000_000

SCHEMA = """
CREATE TABLE IF NOT EXISTS ai_attempt_policy (
 id INTEGER PRIMARY KEY CHECK (id=1),
 monthly_limit INTEGER CHECK (monthly_limit IS NULL OR monthly_limit BETWEEN 0 AND 1000000),
 revision INTEGER NOT NULL CHECK (revision >= 1),
 tracking_started_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS ai_attempt_months (
 month TEXT PRIMARY KEY,
 used INTEGER NOT NULL CHECK (used >= 0)
);
"""


class AdmissionError(HTTPException):
    """The application declined a send before contacting the provider."""


class TargetRefusal(AdmissionError):
    """This model cannot take the attempt. The router may try its next candidate."""


@dataclass(frozen=True)
class _Slot:
    month: str
    model_id: str | None
    probe_until: str | None


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(value: datetime) -> str:
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def migrate(db) -> None:
    sql_script.execute(db, SCHEMA)
    db.execute("""INSERT OR IGNORE INTO ai_attempt_policy(id, monthly_limit, revision, tracking_started_at)
                  VALUES(1, NULL, 1, ?)""", (_stamp(utc_now()),))


def _period():
    now = utc_now()
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    return now, start.strftime("%Y-%m"), (start + timedelta(days=32)).replace(day=1)


def _state(db, month):
    row = db.execute("""SELECT p.monthly_limit, p.revision, p.tracking_started_at,
                               COALESCE(m.used, 0) AS used
                        FROM ai_attempt_policy p LEFT JOIN ai_attempt_months m ON m.month=?
                        WHERE p.id=1""", (month,)).fetchone()
    if row is None:
        raise AdmissionError(503, "The AI attempt allowance is unavailable.")
    return row


def summary(db) -> dict:
    _, month, reset = _period()
    state = dict(_state(db, month))
    limit = state["monthly_limit"]
    return {**state, "month": month, "next_reset_at": _stamp(reset),
            "remaining": None if limit is None else max(0, limit - state["used"])}


def set_limit(db, limit: int | None, expected_revision: int) -> tuple[dict, bool]:
    previous = summary(db)
    if previous["revision"] != expected_revision:
        raise HTTPException(409, "The AI attempt allowance changed. Reload before saving.")
    if previous["monthly_limit"] == limit:
        return previous, False
    db.execute("UPDATE ai_attempt_policy SET monthly_limit=?, revision=revision+1 WHERE id=1", (limit,))
    return previous, True


def _admit(model_id, use_circuit, abandoned) -> _Slot | None:
    # Acquire the write lock before choosing the month or reading the remaining allowance.
    try:
        with store.connection(write=True) as db:
            if abandoned.is_set():
                return None
            now, month, reset = _period()
            state = _state(db, month)
            limit = state["monthly_limit"]
            if limit is not None and state["used"] >= limit:
                headers = {"X-InterviewCheck-Limit": "ai-attempts"}
                if limit:
                    headers["Retry-After"] = str(max(1, int((reset - now).total_seconds()) + 1))
                raise AdmissionError(429, "The workspace monthly AI attempt allowance has been reached.", headers=headers)
            probe_until = None
            if use_circuit and model_id:
                from . import model_circuit
                decision = model_circuit.can_execute(db, model_id)
                if not decision.allowed:
                    raise TargetRefusal(503, "Model circuit is open.", headers={"Retry-After": str(decision.retry_after_s)})
                if decision.state == "half_open":
                    probe_until = db.execute("SELECT half_open_probe_until FROM model_circuit_state WHERE model_id=?",
                                             (model_id,)).fetchone()[0]
            db.execute("""INSERT INTO ai_attempt_months(month, used) VALUES(?, 1)
                          ON CONFLICT(month) DO UPDATE SET used=used+1""", (month,))
        return _Slot(month, model_id, probe_until)
    except sqlite3.Error as exc:
        raise AdmissionError(503, "The AI attempt allowance could not authorize this request.") from exc


def _release_local_refusal(slot: _Slot) -> None:
    try:
        with store.connection(write=True) as db:
            db.execute("UPDATE ai_attempt_months SET used=used-1 WHERE month=? AND used>0", (slot.month,))
            if slot.probe_until:
                db.execute("""UPDATE model_circuit_state SET half_open_probe_until=NULL
                              WHERE model_id=? AND state='half_open' AND half_open_probe_until=?""",
                           (slot.model_id, slot.probe_until))
    except sqlite3.Error as exc:
        raise AdmissionError(503, "A blocked connection could not return its AI allowance slot.") from exc


class _PendingAdmission:
    """Return a committed slot if the awaiting task was cancelled during SQLite I/O."""

    def __init__(self):
        self.abandoned = threading.Event()
        self.lock = threading.Lock()
        self.slot = None

    def acquire(self, model_id, use_circuit):
        slot = _admit(model_id, use_circuit, self.abandoned)
        with self.lock:
            if not self.abandoned.is_set():
                self.slot = slot
                return slot
        if slot is not None:
            _release_local_refusal(slot)
        return None

    def abandon(self):
        with self.lock:
            self.abandoned.set()
            return self.slot


async def _return_slot(slot):
    # A cancelled request still has a duty to reconcile a known local refusal.
    with CancelScope(shield=True):
        await run_in_threadpool(_release_local_refusal, slot)


async def send(fetch, *args, before_send=None, admission_target=None, use_circuit=False, **kwargs):
    from .model_execution_policy import QUOTA_LIMITER, _is_ssrf_error, _rpm_limit

    model_id = admission_target.id if admission_target is not None else None
    pending = _PendingAdmission()
    try:
        slot = await run_in_threadpool(pending.acquire, model_id, use_circuit)
    except asyncio.CancelledError:
        slot = pending.abandon()
        if slot is not None:
            await asyncio.shield(_return_slot(slot))
        raise
    quota_window = None
    try:
        # A cancelled ASGI scope may have deferred cancellation for the DB worker.
        await checkpoint_if_cancelled()
        if before_send is not None:
            await before_send()
        limit = _rpm_limit(admission_target) if model_id else None
        if limit is not None:
            try:
                quota_window = QUOTA_LIMITER.consume(model_id, limit)
            except HTTPException as exc:
                raise TargetRefusal(exc.status_code, exc.detail, headers=exc.headers) from exc
    except BaseException as exc:
        await asyncio.shield(_return_slot(slot))
        if isinstance(exc, HTTPException) and not isinstance(exc, AdmissionError):
            raise AdmissionError(exc.status_code, exc.detail, headers=exc.headers) from exc
        raise
    try:
        return await fetch(*args, **kwargs)
    except (ssrf_guard.SSRFValidationError, HTTPException) as exc:
        if _is_ssrf_error(exc):
            if quota_window is not None:
                QUOTA_LIMITER.release(model_id, quota_window)
            await asyncio.shield(_return_slot(slot))
        raise
