"""CSP violation report collector and sanitized admin viewer."""
import json
import re
import sqlite3
from typing import Any
from urllib.parse import SplitResult, urlsplit, urlunsplit

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse

from . import model_admin, rate_limit, sql_script, store

MAX_BODY_BYTES = 8192
MAX_STORED_REPORTS = 500
MAX_BATCH_REPORTS = 20
ALLOWED_CONTENT_TYPES = frozenset({"application/csp-report", "application/reports+json"})
_CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")
_AUTH_USERINFO_RE = re.compile(r"^(https?://)[^/?#]*@", re.IGNORECASE)

SCHEMA = """
CREATE TABLE IF NOT EXISTS csp_violations (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 received_at TEXT NOT NULL,
 document_uri TEXT NOT NULL,
 violated_directive TEXT NOT NULL,
 effective_directive TEXT NOT NULL,
 blocked_uri TEXT NOT NULL,
 source_file TEXT NOT NULL,
 line_number INTEGER,
 column_number INTEGER,
 disposition TEXT NOT NULL DEFAULT 'enforce',
 status_code INTEGER
);
CREATE INDEX IF NOT EXISTS idx_csp_violations_received ON csp_violations(received_at DESC, id DESC);
"""

router = APIRouter(prefix="/api", tags=["csp-reports"])


def migrate(db: sqlite3.Connection) -> None:
    sql_script.execute(db, SCHEMA)


def _clean_text(value: Any, *, max_len: int = 128) -> str:
    return _CTRL_RE.sub("", value).strip()[:max_len] if isinstance(value, str) else ""


def _clean_int(value: Any, *, hi: int = 1_000_000) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if 0 <= value <= hi else None


def _clean_netloc(parts: SplitResult) -> str:
    host = parts.hostname or ""
    if not host:
        return ""
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    try:
        port = parts.port
    except ValueError:
        port = None
    return f"{host}:{port}" if port is not None else host


def sanitize_uri(value: Any, *, max_len: int = 512) -> str:
    clean = _clean_text(value, max_len=2048)
    if not clean:
        return ""
    lowered = clean.lower()
    if lowered.startswith("data:"):
        return clean.split(",", 1)[0].split(";", 1)[0][:64]
    if lowered.startswith("blob:"):
        inner = sanitize_uri(clean[5:], max_len=max(0, max_len - 5))
        return f"blob:{inner}" if inner else "blob:"
    try:
        parts = urlsplit(clean)
    except ValueError:
        safe = _AUTH_USERINFO_RE.sub(r"\1", clean)
        return safe.split("?", 1)[0].split("#", 1)[0][:max_len]
    if parts.scheme in {"http", "https"}:
        return urlunsplit((parts.scheme.lower(), _clean_netloc(parts), parts.path, "", ""))[:max_len]
    return clean.split("?", 1)[0].split("#", 1)[0][:max_len]


def _normalize_report(raw: dict[str, Any], *, fallback_url: Any = None) -> dict[str, Any] | None:
    doc = sanitize_uri(raw.get("document-uri") or raw.get("documentURL") or fallback_url)
    violated = _clean_text(raw.get("violated-directive") or raw.get("violatedDirective"))
    effective = _clean_text(raw.get("effective-directive") or raw.get("effectiveDirective"))
    effective = effective or (violated.split()[0][:128] if violated else "")
    violated = violated or effective
    blocked = sanitize_uri(raw.get("blocked-uri") or raw.get("blockedURL"))
    source = sanitize_uri(raw.get("source-file") or raw.get("sourceFile"))
    if not any((doc, violated, effective, blocked)):
        return None
    disp = _clean_text(raw.get("disposition"), max_len=16).lower()
    return {
        "document_uri": doc,
        "violated_directive": violated,
        "effective_directive": effective,
        "blocked_uri": blocked,
        "source_file": source,
        "line_number": _clean_int(raw.get("line-number") if "line-number" in raw else raw.get("lineNumber")),
        "column_number": _clean_int(raw.get("column-number") if "column-number" in raw else raw.get("columnNumber")),
        "disposition": disp if disp in {"enforce", "report"} else "enforce",
        "status_code": _clean_int(raw.get("status-code") if "status-code" in raw else raw.get("statusCode"), hi=999),
    }


def _extract_reports(media_type: str, payload: Any) -> list[dict[str, Any]]:
    if media_type == "application/csp-report":
        if not isinstance(payload, dict):
            raise HTTPException(400, "Invalid CSP report payload.")
        body = payload.get("csp-report") if "csp-report" in payload else payload
        if not isinstance(body, dict):
            raise HTTPException(400, "Invalid CSP report payload.")
        item = _normalize_report(body)
        if item is None:
            raise HTTPException(400, "CSP report is missing violation fields.")
        return [item]
    items_raw = [payload] if isinstance(payload, dict) else payload
    if not isinstance(items_raw, list):
        raise HTTPException(400, "Invalid CSP reports payload.")
    out: list[dict[str, Any]] = []
    for entry in items_raw[:MAX_BATCH_REPORTS]:
        if not isinstance(entry, dict) or entry.get("type") not in (None, "csp-violation"):
            continue
        body = entry.get("body") if isinstance(entry.get("body"), dict) else entry
        norm = _normalize_report(body, fallback_url=entry.get("url"))
        if norm is not None:
            out.append(norm)
    return out


@router.post("/csp-report", status_code=204, dependencies=[Depends(rate_limit.limit(rate_limit.CSP_REPORT))])
async def collect_csp_report(request: Request) -> Response:
    media_type = (request.headers.get("content-type") or "").split(";", 1)[0].strip().lower()
    if media_type not in ALLOWED_CONTENT_TYPES:
        raise HTTPException(415, "Unsupported CSP report content type.")
    raw = await request.body()
    if len(raw) > MAX_BODY_BYTES:
        raise HTTPException(413, "Input exceeds the size limit.")
    if not raw.strip():
        raise HTTPException(400, "Empty CSP report payload.")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise HTTPException(400, "Invalid CSP report payload.") from exc
    reports = _extract_reports(media_type, payload)
    if reports:
        now = store.timestamp()
        with store.connection(write=True) as db:
            migrate(db)
            db.executemany(
                """INSERT INTO csp_violations(
                    received_at, document_uri, violated_directive, effective_directive,
                    blocked_uri, source_file, line_number, column_number, disposition, status_code
                ) VALUES (?,?,?,?,?,?,?,?,?,?)""",
                [(now, r["document_uri"], r["violated_directive"], r["effective_directive"], r["blocked_uri"],
                  r["source_file"], r["line_number"], r["column_number"], r["disposition"], r["status_code"]) for r in reports],
            )
            db.execute(
                "DELETE FROM csp_violations WHERE id NOT IN (SELECT id FROM csp_violations ORDER BY id DESC LIMIT ?)",
                (MAX_STORED_REPORTS,),
            )
    return Response(status_code=204)


@router.get("/admin/security/csp-reports", dependencies=[Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def list_csp_reports(limit: int = Query(default=100, ge=1, le=MAX_STORED_REPORTS)) -> JSONResponse:
    with store.connection() as db:
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='csp_violations'").fetchone() is None:
            return JSONResponse({"reports": [], "total": 0}, headers={"Cache-Control": "no-store"})
        total = int(db.execute("SELECT count(*) FROM csp_violations").fetchone()[0])
        rows = db.execute(
            """SELECT id, received_at, document_uri, violated_directive, effective_directive,
                      blocked_uri, source_file, line_number, column_number, disposition, status_code
               FROM csp_violations ORDER BY id DESC LIMIT ?""",
            (limit,),
        ).fetchall()
    return JSONResponse({"reports": [dict(row) for row in rows], "total": total}, headers={"Cache-Control": "no-store"})


@router.delete("/admin/security/csp-reports", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def clear_csp_reports(actor: dict = Depends(model_admin.require_admin)) -> JSONResponse:
    post_commit: list = []
    with store.connection(write=True) as db:
        migrate(db)
        cleared = int(db.execute("DELETE FROM csp_violations").rowcount or 0)
        model_admin._record_audit(
            db, actor=actor, action="admin.security.csp_reports_cleared",
            model_uuid="csp_violations", details={"cleared": cleared}, post_commit=post_commit,
        )
    model_admin._flush_account_audits(post_commit)
    return JSONResponse({"ok": True, "cleared": cleared}, headers={"Cache-Control": "no-store"})
