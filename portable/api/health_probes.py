"""Liveness and deep readiness probe endpoints with strict output minimization."""
from contextlib import closing
from pathlib import Path
import sqlite3

from fastapi import APIRouter
from fastapi.responses import JSONResponse

from . import access, account_db, secret_box, store

DIST = Path(__file__).resolve().parents[1] / "web" / "out"
REQUIRED_REVIEW_TABLES = frozenset({"sessions", "roles", "connected_models"})

router = APIRouter(prefix="/api", tags=["health"])


def _check_review_db() -> str:
    try:
        path = store.db_path()
        if not path.is_file():
            return "error"
        with store.connection() as db:
            mode = db.execute("PRAGMA journal_mode").fetchone()
            if mode is None or str(mode[0]).lower() != "wal":
                return "error"
            rows = db.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sessions','roles','connected_models')"
            ).fetchall()
            if {row[0] for row in rows} != REQUIRED_REVIEW_TABLES:
                return "error"
            for table in REQUIRED_REVIEW_TABLES:
                db.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone()
    except Exception:
        return "error"
    return "ok"


def _check_access_db() -> str:
    if not access.embedded_enabled():
        return "skipped"
    try:
        db_path = account_db.database()
        if not db_path.is_file():
            return "error"
        with closing(sqlite3.connect(f"{db_path.resolve().as_uri()}?mode=ro", uri=True, timeout=5)) as db:
            mode = db.execute("PRAGMA journal_mode").fetchone()
            if mode is None or str(mode[0]).lower() != "wal":
                return "error"
            row = db.execute("PRAGMA user_version").fetchone()
            if row is None or int(row[0]) != account_db.VERSION:
                return "error"
            has_users = db.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='users'"
            ).fetchone()
            if has_users is None:
                return "error"
            db.execute("SELECT 1 FROM users LIMIT 1").fetchone()
    except Exception:
        return "error"
    return "ok"


def _check_secret_box() -> str:
    try:
        if secret_box.key_source() == "file" and not secret_box.key_file_path().is_file():
            return "error"
        active_fn = getattr(secret_box, "active_key_id", None)
        if callable(active_fn):
            key_id = active_fn()
            if not isinstance(key_id, str) or not key_id:
                return "error"
        else:
            token = secret_box.encrypt_secret("readyz-probe", aad="readyz")
            if not isinstance(token, str) or not token:
                return "error"
    except Exception:
        return "error"
    return "ok"


def _check_web_bundle() -> str:
    try:
        if (DIST / "index.html").is_file():
            return "ok"
        if (DIST.parent / ".next-server" / "routes-manifest.json").is_file():
            return "ok"
        return "missing"
    except OSError:
        return "missing"


@router.get("/healthz")
def healthz() -> JSONResponse:
    return JSONResponse(
        {"ok": True, "service": "interviewcheck-api"},
        status_code=200,
        headers={"Cache-Control": "no-store"},
    )


@router.get("/readyz")
def readyz() -> JSONResponse:
    checks = {
        "review_db": _check_review_db(),
        "access_db": _check_access_db(),
        "secret_box": _check_secret_box(),
        "web_bundle": _check_web_bundle(),
    }
    ok = (
        checks["review_db"] == "ok"
        and checks["access_db"] in {"ok", "skipped"}
        and checks["secret_box"] == "ok"
        and checks["web_bundle"] == "ok"
    )
    return JSONResponse(
        {"ok": ok, "checks": checks},
        status_code=200 if ok else 503,
        headers={"Cache-Control": "no-store"},
    )
