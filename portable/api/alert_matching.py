"""Decide which enabled alert rules fire and build the event each one delivers."""
from datetime import datetime, timezone
import sqlite3
from typing import Any
from uuid import uuid4

from . import model_budgets, model_telemetry, store


def in_cooldown(rule: sqlite3.Row, now_dt: datetime) -> bool:
    if not (last := rule["last_triggered_at"]) or (cd := int(rule["cooldown_minutes"] or 0)) <= 0:
        return False
    try:
        prev = datetime.fromisoformat(last)
    except ValueError:
        return False
    return (now_dt - (prev if prev.tzinfo else prev.replace(tzinfo=timezone.utc))).total_seconds() < cd * 60


def match_model(db: sqlite3.Connection, m: sqlite3.Row, trig: str, thresh: float, fleet_usage: dict[str, Any]) -> dict[str, Any] | None:
    mid, base = m["id"], {"model_id": m["id"], "slug": m["slug"], "capability": m["capability"]}
    if trig == "model_error_streak":
        rows = db.execute("SELECT ok FROM model_health_checks WHERE model_id=? ORDER BY checked_at DESC, id DESC LIMIT 50", (mid,)).fetchall()
        streak = 0
        for r in rows:
            if r["ok"] != 0:
                break
            streak += 1
        return {**base, "error_streak": streak, "last_error": m["last_error"]} if streak >= int(thresh) else None
    if trig == "model_uptime_below":
        s = model_telemetry.summarize_model(db, mid)
        if s["total_checks"] > 0 and s["uptime_pct"] is not None and s["uptime_pct"] < thresh:
            return {**base, "uptime_pct": s["uptime_pct"], "total_checks": s["total_checks"]}
    elif trig == "budget_pct_threshold":
        u = fleet_usage.get("models", {}).get(mid, {})
        d_lim, m_lim = u.get("daily_token_limit"), u.get("monthly_cost_limit_usd")
        d_pct = (u.get("daily_tokens", 0) * 100.0 / d_lim) if (d_lim and d_lim > 0) else None
        m_pct = (u.get("monthly_cost_usd", 0.0) * 100.0 / m_lim) if (m_lim and m_lim > 0) else None
        if (d_pct is not None and d_pct >= thresh) or (m_pct is not None and m_pct >= thresh):
            return {**base, "daily_pct": round(d_pct, 2) if d_pct is not None else None, "monthly_pct": round(m_pct, 2) if m_pct is not None else None}
    elif trig == "probe_failed":
        probe = db.execute("SELECT ok, error FROM model_health_checks WHERE model_id=? AND source='probe' ORDER BY checked_at DESC, id DESC LIMIT 1", (mid,)).fetchone()
        if (probe["ok"] == 0) if probe is not None else (m["status"] == "error"):
            return {**base, "error": (probe["error"] if probe else None) or m["last_error"]}
    return None


def evaluate_matches(db: sqlite3.Connection, rule: sqlite3.Row, fleet_usage: dict[str, Any]) -> list[dict[str, Any]]:
    cap, trig, thresh = rule["capability_filter"], rule["trigger_type"], float(rule["threshold_value"])
    models = db.execute("SELECT id,slug,capability,status,last_error FROM connected_models WHERE enabled=1" + (" AND capability=?" if cap else "") + " ORDER BY id ASC", (cap,) if cap else ()).fetchall()
    matches = [hit for m in models if (hit := match_model(db, m, trig, thresh, fleet_usage)) is not None]
    return [] if (trig == "probe_failed" and len(matches) < int(thresh)) else matches


def event_payload(rule: sqlite3.Row, event_name: str, event_key: str, triggered_at: str, matches: list[dict[str, Any]]) -> dict[str, Any]:
    return {"event": event_name, "event_key": event_key, "triggered_at": triggered_at, "matches": matches,
            "rule": {"id": rule["id"], "name": rule["name"], "trigger_type": rule["trigger_type"], "threshold_value": rule["threshold_value"], "capability_filter": rule["capability_filter"]}}


def triggered_rules(now_dt: datetime) -> tuple[list[sqlite3.Row], list[tuple], int]:
    pending, skipped = [], 0
    with store.connection() as db:
        rules = db.execute("SELECT * FROM alert_rules WHERE enabled=1 ORDER BY created_at ASC, id ASC").fetchall()
        fleet_usage = model_budgets.fleet_usage_summary(db)
        for rule in rules:
            if in_cooldown(rule, now_dt):
                skipped += 1
            elif matches := evaluate_matches(db, rule, fleet_usage):
                key = f"{rule['trigger_type']}:{uuid4().hex[:12]}"
                pending.append((rule, key, event_payload(rule, "alert.triggered", key, now_dt.isoformat(), matches)))
    return rules, pending, skipped
