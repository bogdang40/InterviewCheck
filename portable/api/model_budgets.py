"""Per-model token/cost budget ceilings, daily usage metering, and fleet summaries."""
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
import sqlite3
from typing import Any

from . import sql_script

BUDGET_PARAM_DEFAULTS: dict[str, Any] = {
    "daily_token_limit": None,
    "monthly_cost_limit_usd": None,
    "input_cost_per_1m_usd": None,
    "output_cost_per_1m_usd": None,
}
MAX_TOKEN_COUNT = 1_000_000_000_000

SCHEMA = """
CREATE TABLE IF NOT EXISTS model_usage_daily (
 model_id TEXT NOT NULL REFERENCES connected_models(id) ON DELETE CASCADE,
 usage_date TEXT NOT NULL,
 request_count INTEGER NOT NULL DEFAULT 0,
 error_count INTEGER NOT NULL DEFAULT 0,
 input_tokens INTEGER NOT NULL DEFAULT 0,
 output_tokens INTEGER NOT NULL DEFAULT 0,
 estimated_cost_usd REAL NOT NULL DEFAULT 0.0,
 updated_at TEXT NOT NULL,
 PRIMARY KEY (model_id, usage_date)
);
CREATE INDEX IF NOT EXISTS idx_model_usage_date ON model_usage_daily(usage_date, model_id);
"""


@dataclass(frozen=True)
class BudgetDecision:
    allowed: bool
    reason: str | None
    daily_tokens: int
    daily_limit: int | None
    monthly_cost_usd: float
    monthly_limit_usd: float | None


def migrate(db: sqlite3.Connection) -> None:
    sql_script.execute(db, SCHEMA)
    if "unsplit_tokens" not in {row[1] for row in db.execute("PRAGMA table_info(model_usage_daily)")}:
        db.execute("ALTER TABLE model_usage_daily ADD COLUMN unsplit_tokens INTEGER NOT NULL DEFAULT 0")


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _utc_date(today: str | None = None) -> str:
    return today if today else _utc_now().strftime("%Y-%m-%d")


def _finite_number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        fval = float(value)
    except OverflowError:
        return None
    return fval if math.isfinite(fval) else None


def extract_budget_params(raw: dict[str, Any] | None) -> dict[str, Any]:
    params = dict(BUDGET_PARAM_DEFAULTS)
    if not isinstance(raw, dict):
        return params
    daily = raw.get("daily_token_limit")
    if not isinstance(daily, bool) and isinstance(daily, int) and 1 <= daily <= 100_000_000:
        params["daily_token_limit"] = daily
    monthly = _finite_number(raw.get("monthly_cost_limit_usd"))
    if monthly is not None and 0.0 < monthly <= 100_000.0:
        params["monthly_cost_limit_usd"] = monthly
    for rate_key in ("input_cost_per_1m_usd", "output_cost_per_1m_usd"):
        rate = _finite_number(raw.get(rate_key))
        if rate is not None and 0.0 <= rate <= 1000.0:
            params[rate_key] = rate
    return params


def merge_budget_params(clean: dict[str, Any], parameters: dict[str, Any] | None) -> dict[str, Any]:
    extracted = extract_budget_params(parameters)
    for key, value in extracted.items():
        if value is not None:
            clean[key] = value
        else:
            clean.pop(key, None)
    return clean


def _nonneg_int(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, int):
        return min(max(0, value), MAX_TOKEN_COUNT)
    if not math.isfinite(value):
        return None
    return min(max(0, int(value)), MAX_TOKEN_COUNT)


def clamp_tokens(value: Any) -> int:
    return _nonneg_int(value) or 0


@dataclass(frozen=True)
class TokenUsage:
    input_tokens: int = 0
    output_tokens: int = 0
    complete: bool = False
    unsplit_tokens: int = 0


def _reported_count(value: Any) -> bool:
    return type(value) is int and 0 <= value <= MAX_TOKEN_COUNT


def provider_usage(provider: str, response_json: Any, *, capability: str = "") -> TokenUsage:
    usage = response_json.get("usage") if isinstance(response_json, dict) else None
    if not isinstance(usage, dict):
        return TokenUsage()
    if provider == "anthropic":
        raw_in = usage.get("input_tokens") if "input_tokens" in usage else usage.get("prompt_tokens")
        raw_out = usage.get("output_tokens") if "output_tokens" in usage else usage.get("completion_tokens")
    else:
        raw_in = usage.get("prompt_tokens") if "prompt_tokens" in usage else usage.get("input_tokens")
        raw_out = usage.get("completion_tokens") if "completion_tokens" in usage else usage.get("output_tokens")
    in_tokens = _nonneg_int(raw_in)
    out_tokens = _nonneg_int(raw_out)
    raw_total = usage.get("total_tokens")
    total = clamp_tokens(raw_total)
    if in_tokens is None and out_tokens is None:
        if capability == "embedding" and _reported_count(raw_total) and raw_in is None and raw_out is None:
            return TokenUsage(input_tokens=total, complete=True)
        return TokenUsage(unsplit_tokens=total)
    complete = _reported_count(raw_in) and (_reported_count(raw_out) or (capability == "embedding" and raw_out is None))
    if raw_total is not None:
        complete = complete and _reported_count(raw_total) and raw_total == (in_tokens or 0) + (out_tokens or 0)
    unsplit = max(0, total - (in_tokens or 0) - (out_tokens or 0))
    return TokenUsage(in_tokens or 0, out_tokens or 0, complete, unsplit)


def extract_usage(provider: str, response_json: Any) -> tuple[int, int]:
    usage = provider_usage(provider, response_json)
    return usage.input_tokens, usage.output_tokens


def estimate_cost_usd(input_tokens: int, output_tokens: int, config: dict[str, Any] | None) -> float:
    cfg = extract_budget_params(config)
    in_rate = cfg["input_cost_per_1m_usd"] or 0.0
    out_rate = cfg["output_cost_per_1m_usd"] or 0.0
    in_tok = clamp_tokens(input_tokens)
    out_tok = clamp_tokens(output_tokens)
    cost = (in_tok * in_rate + out_tok * out_rate) / 1_000_000.0
    if not math.isfinite(cost):
        return 0.0
    return round(cost, 10)


def _read_usage_totals(db: sqlite3.Connection, model_uuid: str, date_str: str) -> tuple[int, float]:
    daily_row = db.execute(
        "SELECT COALESCE(SUM(input_tokens + output_tokens + unsplit_tokens), 0) AS total_tokens "
        "FROM model_usage_daily WHERE model_id=? AND usage_date=?",
        (model_uuid, date_str),
    ).fetchone()
    month_row = db.execute(
        "SELECT COALESCE(SUM(estimated_cost_usd), 0.0) AS month_cost "
        "FROM model_usage_daily WHERE model_id=? AND usage_date LIKE ?",
        (model_uuid, f"{date_str[:7]}-%"),
    ).fetchone()
    daily_tokens = int(daily_row["total_tokens"] if daily_row else 0)
    monthly_cost = round(float(month_row["month_cost"] if month_row else 0.0), 8)
    return daily_tokens, monthly_cost


def check_budget(
    db: sqlite3.Connection, model_uuid: str | None, config: dict[str, Any] | None, *, today: str | None = None
) -> BudgetDecision:
    cfg = extract_budget_params(config)
    daily_limit, monthly_limit = cfg["daily_token_limit"], cfg["monthly_cost_limit_usd"]
    if not model_uuid:
        return BudgetDecision(True, None, 0, daily_limit, 0.0, monthly_limit)

    daily_tokens, monthly_cost = _read_usage_totals(db, model_uuid, _utc_date(today))
    if daily_limit is not None and daily_tokens >= daily_limit:
        return BudgetDecision(False, "daily_token_limit_exceeded", daily_tokens, daily_limit, monthly_cost, monthly_limit)
    if monthly_limit is not None and monthly_cost >= monthly_limit:
        return BudgetDecision(False, "monthly_cost_limit_exceeded", daily_tokens, daily_limit, monthly_cost, monthly_limit)
    return BudgetDecision(True, None, daily_tokens, daily_limit, monthly_cost, monthly_limit)


def record_usage(
    db: sqlite3.Connection, model_uuid: str | None, *, input_tokens: int, output_tokens: int,
    ok: bool, config: dict[str, Any] | None, usage_date: str | None = None, unsplit_tokens: int = 0,
) -> None:
    if not model_uuid:
        return
    in_tok, out_tok = clamp_tokens(input_tokens), clamp_tokens(output_tokens)
    cost = estimate_cost_usd(in_tok, out_tok, config)
    db.execute(
        """INSERT INTO model_usage_daily(
               model_id, usage_date, request_count, error_count, input_tokens, output_tokens, unsplit_tokens, estimated_cost_usd, updated_at
           ) VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(model_id, usage_date) DO UPDATE SET
               request_count = model_usage_daily.request_count + 1,
               error_count = model_usage_daily.error_count + excluded.error_count,
               input_tokens = model_usage_daily.input_tokens + excluded.input_tokens,
               output_tokens = model_usage_daily.output_tokens + excluded.output_tokens,
               unsplit_tokens = model_usage_daily.unsplit_tokens + excluded.unsplit_tokens,
               estimated_cost_usd = model_usage_daily.estimated_cost_usd + excluded.estimated_cost_usd,
               updated_at = excluded.updated_at""",
        (model_uuid, _utc_date(usage_date), 0 if ok else 1, in_tok, out_tok, clamp_tokens(unsplit_tokens), cost, _utc_now().isoformat()),
    )


def _load_config_dict(raw_json: str | None) -> dict[str, Any]:
    try:
        parsed = json.loads(raw_json or "{}")
    except (ValueError, TypeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _row_usage(row: sqlite3.Row | None) -> tuple[int, int, int, int, int, float]:
    if row is None:
        return (0, 0, 0, 0, 0, 0.0)
    return (int(row["request_count"]), int(row["error_count"]), int(row["input_tokens"]), int(row["output_tokens"]),
            int(row["unsplit_tokens"]), float(row["estimated_cost_usd"]))


def fleet_usage_summary(db: sqlite3.Connection, *, today: str | None = None) -> dict[str, Any]:
    date_str = _utc_date(today)
    month_prefix = date_str[:7]
    models = db.execute(
        "SELECT id, slug, display_name, provider, capability, config_json FROM connected_models "
        "ORDER BY capability ASC, is_default DESC, updated_at DESC, id ASC"
    ).fetchall()
    daily_rows = {
        r["model_id"]: r for r in db.execute(
            "SELECT model_id, request_count, error_count, input_tokens, output_tokens, unsplit_tokens, estimated_cost_usd "
            "FROM model_usage_daily WHERE usage_date=?", (date_str,),
        ).fetchall()
    }
    monthly_rows = {
        r["model_id"]: r for r in db.execute(
            "SELECT model_id, COALESCE(SUM(request_count), 0) AS request_count, "
            "COALESCE(SUM(error_count), 0) AS error_count, COALESCE(SUM(input_tokens), 0) AS input_tokens, "
            "COALESCE(SUM(output_tokens), 0) AS output_tokens, COALESCE(SUM(unsplit_tokens), 0) AS unsplit_tokens, "
            "COALESCE(SUM(estimated_cost_usd), 0.0) AS estimated_cost_usd "
            "FROM model_usage_daily WHERE usage_date LIKE ? GROUP BY model_id", (f"{month_prefix}-%",),
        ).fetchall()
    }

    per_model: dict[str, dict[str, Any]] = {}
    tot_d_tok = tot_d_req = tot_d_err = tot_m_in = tot_m_out = tot_m_req = tot_m_err = over_budget = 0
    tot_d_cost = tot_m_cost = 0.0
    tot_m_unsplit = 0

    for m in models:
        mid = m["id"]
        cfg = extract_budget_params(_load_config_dict(m["config_json"]))
        d_req, d_err, d_in, d_out, d_unsplit, d_cost = _row_usage(daily_rows.get(mid))
        m_req, m_err, m_in, m_out, m_unsplit, m_cost = _row_usage(monthly_rows.get(mid))
        d_tok, m_tok = d_in + d_out + d_unsplit, m_in + m_out + m_unsplit
        d_lim, m_lim = cfg["daily_token_limit"], cfg["monthly_cost_limit_usd"]
        if d_lim is not None and d_tok >= d_lim:
            b_status, over_budget = "daily_token_limit_exceeded", over_budget + 1
        elif m_lim is not None and round(m_cost, 8) >= m_lim:
            b_status, over_budget = "monthly_cost_limit_exceeded", over_budget + 1
        else:
            b_status = "ok"

        tot_d_tok += d_tok
        tot_d_cost += d_cost
        tot_d_req += d_req
        tot_d_err += d_err
        tot_m_in += m_in
        tot_m_out += m_out
        tot_m_unsplit += m_unsplit
        tot_m_cost += m_cost
        tot_m_req += m_req
        tot_m_err += m_err

        per_model[mid] = {
            "model_id": mid, "slug": m["slug"], "display_name": m["display_name"],
            "provider": m["provider"], "capability": m["capability"],
            "daily_requests": d_req, "daily_errors": d_err, "daily_input_tokens": d_in,
            "daily_output_tokens": d_out, "daily_tokens": d_tok, "daily_cost_usd": round(d_cost, 6),
            "daily_unsplit_tokens": d_unsplit, "monthly_unsplit_tokens": m_unsplit,
            "daily_token_limit": d_lim, "monthly_requests": m_req, "monthly_errors": m_err,
            "monthly_input_tokens": m_in, "monthly_output_tokens": m_out, "monthly_tokens": m_tok,
            "monthly_cost_usd": round(m_cost, 6), "monthly_cost_limit_usd": m_lim,
            "request_count": m_req, "error_count": m_err, "budget_status": b_status,
        }

    return {
        "usage_date": date_str,
        "usage_month": month_prefix,
        "summary": {
            "usage_date": date_str, "usage_month": month_prefix, "daily_tokens": tot_d_tok,
            "daily_cost_usd": round(tot_d_cost, 6), "daily_requests": tot_d_req, "daily_errors": tot_d_err,
            "monthly_tokens": tot_m_in + tot_m_out + tot_m_unsplit, "monthly_input_tokens": tot_m_in,
            "monthly_unsplit_tokens": tot_m_unsplit,
            "monthly_output_tokens": tot_m_out, "monthly_cost_usd": round(tot_m_cost, 6),
            "monthly_requests": tot_m_req, "monthly_errors": tot_m_err,
            "request_count": tot_m_req, "error_count": tot_m_err, "over_budget_models": over_budget,
        },
        "models": per_model,
    }
