"""OpenMetrics / Prometheus and JSON observability export for FastAPI."""
from datetime import datetime, timezone
import hmac
import os
import sqlite3
import threading
import time
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse

from . import account_db, model_admin, rate_limit, store

LATENCY_BUCKETS_MS: tuple[int, ...] = (5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000)
_ALLOWED_METHODS = frozenset({"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"})
_MAX_ROUTES = 256
PROMETHEUS_MEDIA_TYPE = "text/plain; version=0.0.4; charset=utf-8"


def _fmt_labels(labels: dict[str, Any]) -> str:
    if not labels:
        return ""
    items = [f'{k}="{str(v).replace(chr(92), chr(92)*2).replace(chr(10), chr(92)+"n").replace(chr(34), chr(92)+chr(34))}"' for k, v in labels.items()]
    return "{" + ",".join(items) + "}"


class MetricsRegistry:
    """Thread-safe in-memory HTTP counter and latency histogram store."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._routes: set[str] = set()
        self._requests: dict[tuple[str, str, int], int] = {}
        self._hist_buckets: dict[tuple[str, str], list[int]] = {}
        self._hist_sums: dict[tuple[str, str], float] = {}
        self._hist_counts: dict[tuple[str, str], int] = {}
        self._rate_limit_rejections = 0

    def observe(self, method: str, route: str, status: int, duration_ms: float) -> None:
        clean_method = method.upper() if isinstance(method, str) and method.upper() in _ALLOWED_METHODS else "OTHER"
        elapsed = max(0.0, float(duration_ms))
        with self._lock:
            if route not in self._routes:
                if len(self._routes) < _MAX_ROUTES:
                    self._routes.add(route)
                else:
                    route = "<other>"
            req_key = (clean_method, route, int(status))
            self._requests[req_key] = self._requests.get(req_key, 0) + 1
            if status == 429:
                self._rate_limit_rejections += 1
            hist_key = (clean_method, route)
            buckets = self._hist_buckets.setdefault(hist_key, [0] * (len(LATENCY_BUCKETS_MS) + 1))
            for idx, bound in enumerate(LATENCY_BUCKETS_MS):
                if elapsed <= bound:
                    buckets[idx] += 1
            buckets[-1] += 1
            self._hist_sums[hist_key] = self._hist_sums.get(hist_key, 0.0) + elapsed
            self._hist_counts[hist_key] = self._hist_counts.get(hist_key, 0) + 1

    def snapshot_http(self) -> dict[str, Any]:
        with self._lock:
            requests = [{"method": m, "route": r, "status": s, "count": c} for (m, r, s), c in sorted(self._requests.items())]
            histograms = [
                {
                    "method": m,
                    "route": r,
                    "buckets": {**{str(b): buckets[i] for i, b in enumerate(LATENCY_BUCKETS_MS)}, "+Inf": buckets[-1]},
                    "sum_ms": round(self._hist_sums[(m, r)], 3),
                    "count": self._hist_counts[(m, r)],
                }
                for (m, r), buckets in sorted(self._hist_buckets.items())
            ]
            return {"requests": requests, "duration_ms_histograms": histograms, "rate_limit_rejections_total": self._rate_limit_rejections}

    def reset(self) -> None:
        with self._lock:
            self._routes.clear()
            self._requests.clear()
            self._hist_buckets.clear()
            self._hist_sums.clear()
            self._hist_counts.clear()
            self._rate_limit_rejections = 0


REGISTRY = MetricsRegistry()


def _route_template(scope: dict[str, Any]) -> str:
    route = scope.get("route")
    if route is not None:
        tmpl = getattr(route, "path_format", None) or getattr(route, "path", None)
        if isinstance(tmpl, str):
            root = scope.get("root_path", "")
            if isinstance(root, str) and root and not tmpl.startswith(root):
                tmpl = f"{root.rstrip('/')}/{tmpl.lstrip('/')}" if tmpl else root
            return tmpl or "/"
    return "<unmatched>"


class MetricsMiddleware:
    """ASGI middleware recording bounded-cardinality route counters and latency histograms."""

    def __init__(self, app, *, registry: MetricsRegistry | None = None) -> None:
        self.app = app
        self.registry = registry or REGISTRY

    async def __call__(self, scope, receive, send) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return
        start = time.perf_counter()
        status_code = 500

        async def send_wrapper(message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = int(message.get("status", 200))
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            self.registry.observe(scope.get("method", "GET"), _route_template(scope), status_code, (time.perf_counter() - start) * 1000.0)


def _wal_bytes(db_file) -> int:
    try:
        wal = db_file.with_name(db_file.name + "-wal")
        return int(wal.stat().st_size) if wal.is_file() else 0
    except OSError:
        return 0


def _table_exists(db: sqlite3.Connection, name: str, *, include_views: bool = False) -> bool:
    sql = "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name=?" if include_views else "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
    return db.execute(sql, (name,)).fetchone() is not None


def _access_page_count(access_path) -> int:
    if access_path is None or not access_path.is_file():
        return 0
    try:
        conn = sqlite3.connect(f"file:{access_path.resolve()}?mode=ro", uri=True, timeout=2)
        try:
            row = conn.execute("PRAGMA page_count").fetchone()
            return int(row[0]) if row else 0
        finally:
            conn.close()
    except sqlite3.Error:
        return 0


def collect_metrics(registry: MetricsRegistry | None = None) -> dict[str, Any]:
    reg = registry or REGISTRY
    review_path = store.db_path()
    try:
        access_path = account_db.database()
    except HTTPException:
        access_path = None
    wal_bytes = {"review": _wal_bytes(review_path), "access": _wal_bytes(access_path) if access_path else 0}
    page_count = {"review": 0, "access": _access_page_count(access_path)}
    connected_models: list[dict[str, Any]] = []
    model_checks: list[dict[str, Any]] = []
    model_daily_tokens: list[dict[str, Any]] = []
    sessions = {"active": 0, "finished": 0, "archived": 0, "trashed": 0}

    if review_path.is_file():
        try:
            with store.connection() as db:
                row = db.execute("PRAGMA page_count").fetchone()
                page_count["review"] = int(row[0]) if row else 0
                if _table_exists(db, "connected_models"):
                    connected_models = [
                        {"capability": r["capability"], "status": r["status"], "count": int(r["cnt"])}
                        for r in db.execute("SELECT capability, status, COUNT(*) AS cnt FROM connected_models GROUP BY capability, status ORDER BY capability, status")
                    ]
                    if _table_exists(db, "model_health_checks"):
                        model_checks = [
                            {"capability": r["capability"], "ok": r["ok"], "count": int(r["cnt"])}
                            for r in db.execute("SELECT m.capability AS capability, CASE WHEN h.ok=1 THEN 'true' ELSE 'false' END AS ok, COUNT(*) AS cnt FROM model_health_checks h JOIN connected_models m ON m.id=h.model_id GROUP BY m.capability, h.ok ORDER BY m.capability, ok")
                        ]
                    if _table_exists(db, "model_usage_daily"):
                        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
                        model_daily_tokens = [
                            {"capability": r["capability"], "tokens": int(r["tokens"])}
                            for r in db.execute("SELECT m.capability AS capability, COALESCE(SUM(u.input_tokens + u.output_tokens), 0) AS tokens FROM model_usage_daily u JOIN connected_models m ON m.id=u.model_id WHERE u.usage_date=? GROUP BY m.capability ORDER BY m.capability", (today,))
                        ]
                if _table_exists(db, "interview_catalog", include_views=True):
                    for r in db.execute("SELECT lifecycle, COUNT(*) AS cnt FROM interview_catalog GROUP BY lifecycle"):
                        if r["lifecycle"] in sessions:
                            sessions[r["lifecycle"]] = int(r["cnt"])
                if _table_exists(db, "session_trash"):
                    trashed = db.execute("SELECT COUNT(*) FROM session_trash").fetchone()
                    sessions["trashed"] = int(trashed[0]) if trashed else 0
        except sqlite3.Error:
            pass

    return {
        "http": reg.snapshot_http(),
        "sqlite_wal_bytes": wal_bytes,
        "sqlite_page_count": page_count,
        "connected_models": connected_models,
        "model_checks": model_checks,
        "model_daily_tokens": model_daily_tokens,
        "sessions": sessions,
    }


def _emit_family(lines: list[str], name: str, kind: str, help_text: str, samples: list[tuple[dict[str, Any], int | float]]) -> None:
    lines.extend([f"# HELP {name} {help_text}", f"# TYPE {name} {kind}"])
    for labels, value in samples:
        lines.append(f"{name}{_fmt_labels(labels)} {value}")


def render_prometheus(snapshot: dict[str, Any]) -> str:
    lines: list[str] = []
    http = snapshot["http"]
    _emit_family(lines, "ic_http_requests_total", "counter", "Total HTTP requests by route template and status.", [({"method": i["method"], "route": i["route"], "status": i["status"]}, i["count"]) for i in http["requests"]])
    lines.extend(["# HELP ic_http_request_duration_ms HTTP request duration in milliseconds.", "# TYPE ic_http_request_duration_ms histogram"])
    for hist in http["duration_ms_histograms"]:
        for bound, count in hist["buckets"].items():
            lines.append(f"ic_http_request_duration_ms_bucket{_fmt_labels({'method': hist['method'], 'route': hist['route'], 'le': bound})} {count}")
        base = _fmt_labels({"method": hist["method"], "route": hist["route"]})
        lines.extend([f"ic_http_request_duration_ms_sum{base} {hist['sum_ms']}", f"ic_http_request_duration_ms_count{base} {hist['count']}"])
    _emit_family(lines, "ic_rate_limit_rejections_total", "counter", "Total HTTP 429 rate-limit rejections.", [({}, http["rate_limit_rejections_total"])])
    _emit_family(lines, "ic_sqlite_wal_bytes", "gauge", "Current SQLite WAL file size in bytes.", [({"db": db}, sz) for db, sz in snapshot["sqlite_wal_bytes"].items()])
    _emit_family(lines, "ic_sqlite_page_count", "gauge", "Current SQLite database page count.", [({"db": db}, pg) for db, pg in snapshot["sqlite_page_count"].items()])
    _emit_family(lines, "ic_connected_models_total", "gauge", "Connected model count by capability and status.", [({"capability": i["capability"], "status": i["status"]}, i["count"]) for i in snapshot["connected_models"]])
    _emit_family(lines, "ic_model_checks_total", "gauge", "Recorded model health checks by capability and outcome.", [({"capability": i["capability"], "ok": i["ok"]}, i["count"]) for i in snapshot["model_checks"]])
    _emit_family(lines, "ic_model_daily_tokens_total", "gauge", "Daily model tokens consumed (UTC) by capability.", [({"capability": i["capability"]}, i["tokens"]) for i in snapshot["model_daily_tokens"]])
    _emit_family(lines, "ic_sessions_total", "gauge", "Interview session count by lifecycle state.", [({"lifecycle": lc}, cnt) for lc, cnt in snapshot["sessions"].items()])
    return "\n".join(lines) + "\n"


async def _require_metrics_access(request: Request) -> None:
    auth_header = request.headers.get("authorization", "")
    configured = os.getenv("INTERVIEWCHECK_METRICS_TOKEN", "").strip()
    if auth_header:
        scheme, _, presented = auth_header.partition(" ")
        if configured and scheme.lower() == "bearer" and presented and hmac.compare_digest(presented.encode("utf-8"), configured.encode("utf-8")):
            return
        raise HTTPException(401, "Invalid metrics credentials.")
    await model_admin.require_admin(request)


router = APIRouter(tags=["observability"])


@router.get("/api/admin/metrics", dependencies=[Depends(_require_metrics_access), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def get_admin_metrics(request: Request, format: Literal["prometheus", "json"] = Query(default="prometheus")):
    registry = getattr(request.app.state, "metrics_registry", None) or REGISTRY
    snapshot = collect_metrics(registry)
    headers = {"Cache-Control": "no-store"}
    if format == "json":
        return JSONResponse(content=snapshot, headers=headers)
    return Response(content=render_prometheus(snapshot), media_type=PROMETHEUS_MEDIA_TYPE, headers=headers)
