"""Model degradation and budget threshold webhook alert rules and delivery."""
from datetime import datetime, timezone
import hashlib, hmac, inspect, json, math, sqlite3
from typing import Any, Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query
import httpx
from pydantic import Field, SecretStr, field_validator, model_validator
from starlette.concurrency import run_in_threadpool

from . import alert_matching, model_admin, rate_limit, secret_box, sql_script, ssrf_guard, store
from .alert_matching import event_payload as _event_payload
from .error_sanitizer import sanitize_error_text
from .model_schemas import Capability
from .models import Input

TriggerType = Literal["model_error_streak", "model_uptime_below", "budget_pct_threshold", "probe_failed"]
TRIGGER_TYPES: tuple[str, ...] = ("model_error_streak", "model_uptime_below", "budget_pct_threshold", "probe_failed")
_BOUNDS = {"model_error_streak": (1.0, 50.0, True), "model_uptime_below": (0.0, 100.0, False), "budget_pct_threshold": (1.0, 1000.0, False), "probe_failed": (1.0, 100.0, True)}
SCHEMA = """CREATE TABLE IF NOT EXISTS alert_rules (
 id TEXT PRIMARY KEY, name TEXT NOT NULL,
 trigger_type TEXT NOT NULL CHECK(trigger_type IN ('model_error_streak','model_uptime_below','budget_pct_threshold','probe_failed')),
 threshold_value REAL NOT NULL, capability_filter TEXT, webhook_url TEXT NOT NULL, encrypted_signing_secret TEXT, secret_hint TEXT,
 enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)), cooldown_minutes INTEGER NOT NULL DEFAULT 15,
 last_triggered_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_alert_rules_enabled ON alert_rules(enabled, trigger_type);
CREATE TABLE IF NOT EXISTS alert_deliveries (
 id INTEGER PRIMARY KEY AUTOINCREMENT, rule_id TEXT NOT NULL REFERENCES alert_rules(id) ON DELETE CASCADE,
 event_key TEXT NOT NULL, ok INTEGER NOT NULL CHECK(ok IN (0,1)), http_status INTEGER, error TEXT, delivered_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS idx_alert_deliveries_rule_at ON alert_deliveries(rule_id, delivered_at DESC, id DESC);"""
router = APIRouter(prefix="/api/admin/alerts", tags=["admin-alerts"])
_READ = [Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))]
_WRITE = [Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))]
_EVAL = [*_WRITE, Depends(rate_limit.limit(rate_limit.ADMIN_PROBE))]

def migrate(db: sqlite3.Connection) -> None:
    sql_script.execute(db, SCHEMA)

def _check_name(value: str | None) -> str | None:
    if value is not None and any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise ValueError("Alert rule name contains invalid control characters.")
    return value

def _validate_threshold(trigger_type: str, value: float) -> float:
    fval, (lo, hi, must_int) = float(value), _BOUNDS[trigger_type]
    if not math.isfinite(fval) or (fval <= lo if trigger_type == "model_uptime_below" else fval < lo) or fval > hi or (must_int and fval != float(int(fval))):
        raise ValueError(f"Invalid threshold for {trigger_type}.")
    return fval

class AlertRuleCreateInput(Input):
    name: str = Field(min_length=1, max_length=120)
    trigger_type: TriggerType
    threshold_value: float = Field(allow_inf_nan=False)
    capability_filter: Capability | None = None
    webhook_url: str = Field(min_length=8, max_length=512)
    signing_secret: SecretStr | None = Field(default=None, max_length=512)
    enabled: bool = True
    cooldown_minutes: int = Field(default=15, ge=0, le=10080)
    _valid_name = field_validator("name")(_check_name)

    @model_validator(mode="after")
    def validate_rule(self):
        self.threshold_value = _validate_threshold(self.trigger_type, self.threshold_value)
        if self.signing_secret is not None and self.signing_secret.get_secret_value().strip() == "":
            raise ValueError("Provide a non-empty signing_secret or omit it.")
        return self

class AlertRuleUpdateInput(Input):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    trigger_type: TriggerType | None = None
    threshold_value: float | None = Field(default=None, allow_inf_nan=False)
    capability_filter: Capability | None = None
    webhook_url: str | None = Field(default=None, min_length=8, max_length=512)
    signing_secret: SecretStr | None = Field(default=None, max_length=512)
    clear_signing_secret: bool = False
    enabled: bool | None = None
    cooldown_minutes: int | None = Field(default=None, ge=0, le=10080)
    _valid_name = field_validator("name")(_check_name)

    @model_validator(mode="after")
    def validate_patch(self):
        if not self.model_fields_set:
            raise ValueError("Specify at least one field to update.")
        if any(f in self.model_fields_set and getattr(self, f) is None for f in ("name", "trigger_type", "threshold_value", "webhook_url", "enabled", "cooldown_minutes")):
            raise ValueError("Required alert rule fields cannot be null.")
        if self.clear_signing_secret and self.signing_secret is not None and self.signing_secret.get_secret_value().strip() != "":
            raise ValueError("Cannot provide signing_secret and clear_signing_secret together.")
        return self

def public_rule(r: sqlite3.Row) -> dict[str, Any]:
    return {k: (bool(r[k]) if k == "enabled" else r[k]) for k in ("id", "name", "trigger_type", "threshold_value",
            "capability_filter", "webhook_url", "secret_hint", "enabled", "cooldown_minutes", "last_triggered_at", "created_at", "updated_at")} | {"has_signing_secret": bool(r["encrypted_signing_secret"])}

def public_delivery(r: sqlite3.Row) -> dict[str, Any]:
    return {k: (bool(r[k]) if k == "ok" else r[k]) for k in ("id", "rule_id", "event_key", "ok", "http_status", "error", "delivered_at")}

def _get_rule(db: sqlite3.Connection, rule_id: str) -> sqlite3.Row:
    if (row := db.execute("SELECT * FROM alert_rules WHERE id=?", (rule_id,)).fetchone()) is None:
        raise HTTPException(404, "Alert rule not found.")
    return row

def _load_rule(rule_id: str) -> sqlite3.Row:
    with store.connection() as db:
        return _get_rule(db, rule_id)

async def _validate_webhook(url: str) -> str:
    try:
        return await ssrf_guard.validate_endpoint_url_async(url, provider="openai_compatible")
    except ssrf_guard.SSRFValidationError as exc:
        raise HTTPException(400, sanitize_error_text(str(exc), "Invalid webhook URL.")) from exc

async def _default_dispatch(url: str, body: bytes, headers: dict[str, str]) -> tuple[bool, int | None, str | None]:
    validated = await ssrf_guard.validate_endpoint_url_async(url, provider="openai_compatible", resolve_dns=True)
    try:
        async with httpx.AsyncClient(timeout=5.0, follow_redirects=False, trust_env=False, transport=ssrf_guard.SafeAsyncTransport()) as client:
            resp = await client.post(validated, content=body, headers=headers)
    except httpx.TimeoutException:
        return False, None, "Webhook delivery timed out."
    except (httpx.HTTPError, OSError):
        return False, None, "Could not reach webhook endpoint."
    if 200 <= resp.status_code < 300:
        return True, resp.status_code, None
    return False, resp.status_code, (f"Webhook redirected (HTTP {resp.status_code}). Redirects are blocked." if 300 <= resp.status_code < 400 else f"Webhook returned HTTP {resp.status_code}.")

dispatch_fn = _default_dispatch

async def _deliver(rule: sqlite3.Row, payload: dict[str, Any], event_name: str, event_key: str) -> tuple[bool, int | None, str | None]:
    body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode("utf-8")
    headers = {"Content-Type": "application/json", "X-InterviewCheck-Event": event_name, "X-InterviewCheck-Delivery": event_key}
    if rule["encrypted_signing_secret"]:
        try:
            secret = secret_box.decrypt_secret(rule["encrypted_signing_secret"], aad=rule["id"])
        except secret_box.SecretBoxError:
            return False, None, "Stored webhook signing secret could not be decrypted."
        if secret:
            headers["X-InterviewCheck-Signature"] = "sha256=" + hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    try:
        if dispatch_fn is not _default_dispatch:
            ssrf_guard.validate_endpoint_url(rule["webhook_url"], provider="openai_compatible", resolve_dns=False)
        res = dispatch_fn(rule["webhook_url"], body, headers)
        res = await res if inspect.isawaitable(res) else res
    except ssrf_guard.SSRFValidationError as exc:
        return False, None, sanitize_error_text(str(exc), "Webhook endpoint blocked by SSRF policy.")
    except Exception as exc:
        return False, None, sanitize_error_text(str(exc), "Webhook delivery failed.")
    if isinstance(res, tuple) and len(res) == 3:
        return bool(res[0]), res[1], (sanitize_error_text(str(res[2]), "Webhook failed.") if res[2] else None)
    if isinstance(res, int):
        return (200 <= res < 300), res, (None if 200 <= res < 300 else f"Webhook returned HTTP {res}.")
    return True, 200, None

def _record_delivery(db: sqlite3.Connection, rule_id: str, event_key: str, ok: bool, status: int | None, error: str | None, at: str) -> dict[str, Any]:
    safe_err = sanitize_error_text(error, "Webhook delivery failed.") if (not ok and error) else None
    cur = db.execute("INSERT INTO alert_deliveries(rule_id,event_key,ok,http_status,error,delivered_at) VALUES (?,?,?,?,?,?)", (rule_id, event_key, 1 if ok else 0, status, safe_err, at))
    return public_delivery(db.execute("SELECT * FROM alert_deliveries WHERE id=?", (cur.lastrowid,)).fetchone())

@router.get("", dependencies=_READ)
def list_alerts(limit: int = Query(default=50, ge=1, le=200)):
    with store.connection() as db:
        return {"rules": [public_rule(r) for r in db.execute("SELECT * FROM alert_rules ORDER BY created_at DESC, id ASC").fetchall()],
                "deliveries": [public_delivery(d) for d in db.execute("SELECT * FROM alert_deliveries ORDER BY delivered_at DESC, id DESC LIMIT ?", (limit,)).fetchall()]}

@router.post("", status_code=201, dependencies=_WRITE)
async def create_alert(item: AlertRuleCreateInput, actor: dict = Depends(model_admin.require_admin)):
    webhook_url = await _validate_webhook(item.webhook_url)
    return await run_in_threadpool(_insert_rule, item, webhook_url, actor)

def _insert_rule(item: AlertRuleCreateInput, webhook_url: str, actor: dict) -> dict[str, Any]:
    rule_id, now, post_commit = str(uuid4()), store.timestamp(), []
    raw = item.signing_secret.get_secret_value().strip() if item.signing_secret is not None else ""
    enc, hint = (secret_box.encrypt_secret(raw, aad=rule_id), secret_box.mask_key_hint(raw)) if raw else (None, None)
    with store.connection(write=True) as db:
        db.execute("INSERT INTO alert_rules(id,name,trigger_type,threshold_value,capability_filter,webhook_url,encrypted_signing_secret,secret_hint,enabled,cooldown_minutes,last_triggered_at,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,NULL,?,?)",
                   (rule_id, item.name, item.trigger_type, item.threshold_value, item.capability_filter, webhook_url, enc, hint, 1 if item.enabled else 0, item.cooldown_minutes, now, now))
        created = public_rule(_get_rule(db, rule_id))
        model_admin._record_audit(db, actor=actor, action="admin.alert.create", model_uuid=rule_id, details={"name": created["name"], "trigger_type": created["trigger_type"]}, post_commit=post_commit)
    model_admin._flush_account_audits(post_commit)
    return {"rule": created}

@router.patch("/{rule_id}", dependencies=_WRITE)
async def update_alert(rule_id: UUID, item: AlertRuleUpdateInput, actor: dict = Depends(model_admin.require_admin)):
    rid = str(rule_id)
    ex = await run_in_threadpool(_load_rule, rid)
    trig = item.trigger_type if item.trigger_type is not None else ex["trigger_type"]
    try:
        thresh = _validate_threshold(trig, item.threshold_value if item.threshold_value is not None else ex["threshold_value"])
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    webhook_url = await _validate_webhook(item.webhook_url) if item.webhook_url is not None else ex["webhook_url"]
    enc, hint = ex["encrypted_signing_secret"], ex["secret_hint"]
    raw = item.signing_secret.get_secret_value().strip() if item.signing_secret is not None else ""
    if item.clear_signing_secret:
        enc, hint = None, None
    elif "signing_secret" in item.model_fields_set and raw:
        enc, hint = secret_box.encrypt_secret(raw, aad=rid), secret_box.mask_key_hint(raw)
    cap = item.capability_filter if "capability_filter" in item.model_fields_set else ex["capability_filter"]
    vals = (item.name if item.name is not None else ex["name"], trig, thresh, cap, webhook_url, enc, hint,
            1 if (item.enabled if item.enabled is not None else bool(ex["enabled"])) else 0,
            item.cooldown_minutes if item.cooldown_minutes is not None else ex["cooldown_minutes"], store.timestamp(), rid)
    return await run_in_threadpool(_save_rule_update, rid, vals, actor)

def _save_rule_update(rid: str, vals: tuple, actor: dict) -> dict[str, Any]:
    post_commit: list = []
    with store.connection(write=True) as db:
        db.execute("UPDATE alert_rules SET name=?,trigger_type=?,threshold_value=?,capability_filter=?,webhook_url=?,encrypted_signing_secret=?,secret_hint=?,enabled=?,cooldown_minutes=?,updated_at=? WHERE id=?", vals)
        updated = public_rule(_get_rule(db, rid))
        model_admin._record_audit(db, actor=actor, action="admin.alert.update", model_uuid=rid, details={"name": updated["name"], "enabled": updated["enabled"]}, post_commit=post_commit)
    model_admin._flush_account_audits(post_commit)
    return {"rule": updated}

@router.delete("/{rule_id}", dependencies=_WRITE)
def delete_alert(rule_id: UUID, actor: dict = Depends(model_admin.require_admin)):
    rid, post_commit = str(rule_id), []
    with store.connection(write=True) as db:
        row = _get_rule(db, rid)
        db.execute("DELETE FROM alert_rules WHERE id=?", (rid,))
        model_admin._record_audit(db, actor=actor, action="admin.alert.delete", model_uuid=rid, details={"name": row["name"]}, post_commit=post_commit)
    model_admin._flush_account_audits(post_commit)
    return {"deleted": True, "id": rid}

@router.post("/evaluate", dependencies=_EVAL)
async def evaluate_alerts(actor: dict = Depends(model_admin.require_admin)):
    rules, pending, skipped = await run_in_threadpool(alert_matching.triggered_rules, datetime.now(timezone.utc))
    results = [(rule, key, await _deliver(rule, payload, "alert.triggered", key)) for rule, key, payload in pending]
    return await run_in_threadpool(_record_evaluation, actor, results, len(rules), len(pending), skipped)

def _record_evaluation(actor: dict, results: list[tuple], evaluated: int, triggered: int, skipped: int) -> dict[str, Any]:
    deliveries, post_commit = [], []
    with store.connection(write=True) as db:
        for rule, key, (ok, status, err) in results:
            if db.execute("SELECT 1 FROM alert_rules WHERE id=?", (rule["id"],)).fetchone() is None:
                continue
            at = store.timestamp()
            try:
                deliveries.append(_record_delivery(db, rule["id"], key, ok, status, err, at))
            except sqlite3.IntegrityError:
                continue
            if ok:
                db.execute("UPDATE alert_rules SET last_triggered_at=?, updated_at=? WHERE id=?", (at, at, rule["id"]))
        model_admin._record_audit(db, actor=actor, action="admin.alert.evaluate", model_uuid="fleet",
                                  details={"evaluated": evaluated, "triggered": triggered, "skipped_cooldown": skipped, "delivered": sum(1 for d in deliveries if d["ok"])}, post_commit=post_commit)
    model_admin._flush_account_audits(post_commit)
    return {"evaluated": evaluated, "triggered": triggered, "skipped_cooldown": skipped, "deliveries": deliveries}

@router.post("/{rule_id}/test", dependencies=_EVAL)
async def test_alert(rule_id: UUID, actor: dict = Depends(model_admin.require_admin)):
    rid, event_key = str(rule_id), f"test:{uuid4().hex[:12]}"
    rule = await run_in_threadpool(_load_rule, rid)
    ok, status, err = await _deliver(rule, _event_payload(rule, "alert.test", event_key, store.timestamp(), []), "alert.test", event_key)
    return await run_in_threadpool(_record_test_delivery, actor, rid, event_key, ok, status, err)

def _record_test_delivery(actor: dict, rid: str, event_key: str, ok: bool, status: int | None, err: str | None) -> dict[str, Any]:
    post_commit: list = []
    with store.connection(write=True) as db:
        _get_rule(db, rid)
        try:
            delivery = _record_delivery(db, rid, event_key, ok, status, err, store.timestamp())
        except sqlite3.IntegrityError as exc:
            raise HTTPException(404, "Alert rule not found.") from exc
        model_admin._record_audit(db, actor=actor, action="admin.alert.test", model_uuid=rid, details={"ok": ok, "http_status": status}, post_commit=post_commit)
    model_admin._flush_account_audits(post_commit)
    return {"ok": ok, "delivery": delivery}
