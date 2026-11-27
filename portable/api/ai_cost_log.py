"""One row per AI provider call: who asked, for what, which provider and model, tokens and cost.

No prompt or answer text is stored. The caller's account comes from the sign-in check that guards
every AI route (access.require_entitlement / require_admin_session), passed down in a context variable.
Until the workspace has companies of its own, the company is the account's email domain.
"""
from contextvars import ContextVar
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

from . import model_budgets, sql_script

SCHEMA = """
CREATE TABLE IF NOT EXISTS ai_cost_log (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 at TEXT NOT NULL,
 day TEXT NOT NULL,
 account_email TEXT,
 company TEXT NOT NULL DEFAULT '',
 capability TEXT NOT NULL,
 provider TEXT NOT NULL,
 model_id TEXT NOT NULL,
 model_name TEXT NOT NULL DEFAULT '',
 model_slug TEXT,
 ok INTEGER NOT NULL CHECK (ok IN (0,1)),
 http_status INTEGER,
 latency_ms INTEGER,
 input_tokens INTEGER NOT NULL DEFAULT 0,
 output_tokens INTEGER NOT NULL DEFAULT 0,
 cost_usd REAL NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_ai_cost_log_day ON ai_cost_log(day, id);
CREATE INDEX IF NOT EXISTS idx_ai_cost_log_company ON ai_cost_log(company, day);
"""

KEEP_DAYS = 400
LOCAL = "This workstation"

_actor: ContextVar[str | None] = ContextVar("ai_cost_actor", default=None)
_pruned_day: list[str] = [""]


def migrate(db) -> None:
    sql_script.execute(db, SCHEMA)
    columns = {row[1] for row in db.execute("PRAGMA table_info(ai_cost_log)")}
    if "estimate_status" not in columns:
        db.execute("""ALTER TABLE ai_cost_log ADD COLUMN estimate_status TEXT NOT NULL DEFAULT 'unknown'
                      CHECK (estimate_status IN ('estimated', 'missing_rates', 'missing_usage', 'unknown'))""")
    if "unsplit_tokens" not in columns:
        db.execute("ALTER TABLE ai_cost_log ADD COLUMN unsplit_tokens INTEGER NOT NULL DEFAULT 0")


def set_actor(user: dict[str, Any] | None) -> None:
    """Remember who is signed in for AI calls made while serving this request."""
    email = (user or {}).get("email")
    _actor.set(email.strip().casefold() if isinstance(email, str) and email.strip() else None)


def company_of(email: str | None) -> str:
    if not email or "@" not in email:
        return LOCAL
    return email.rsplit("@", 1)[1]


def estimate_status(usage: model_budgets.TokenUsage, config: dict | None) -> str:
    if not usage.complete:
        return "missing_usage"
    rates = model_budgets.extract_budget_params(config)
    if ((usage.input_tokens and rates["input_cost_per_1m_usd"] is None)
            or (usage.output_tokens and rates["output_cost_per_1m_usd"] is None)):
        return "missing_rates"
    return "estimated"


def record(db, target, *, ok: bool, http_status: int | None, latency_ms: int | None,
           usage: model_budgets.TokenUsage) -> None:
    now = datetime.now(timezone.utc)
    day = now.date().isoformat()
    if _pruned_day[0] != day:
        db.execute("DELETE FROM ai_cost_log WHERE day<?", ((now.date() - timedelta(days=KEEP_DAYS)).isoformat(),))
        _pruned_day[0] = day
    email = _actor.get()
    db.execute(
        """INSERT INTO ai_cost_log(at,day,account_email,company,capability,provider,model_id,model_name,model_slug,
                                   ok,http_status,latency_ms,input_tokens,output_tokens,cost_usd,estimate_status,unsplit_tokens)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (now.isoformat().replace("+00:00", "Z"), day, email, company_of(email), target.capability, target.provider,
         target.model_id, target.display_name or "", target.slug, 1 if ok else 0, http_status, latency_ms,
         usage.input_tokens, usage.output_tokens, model_budgets.estimate_cost_usd(usage.input_tokens, usage.output_tokens, target.config),
         estimate_status(usage, target.config), usage.unsplit_tokens),
    )


SUMS = """COUNT(*) AS requests, SUM(1-ok) AS errors, SUM(input_tokens) AS input_tokens,
          SUM(output_tokens) AS output_tokens, SUM(unsplit_tokens) AS unsplit_tokens, ROUND(SUM(cost_usd), 6) AS cost_usd,
          COUNT(*) FILTER (WHERE estimate_status='estimated') AS estimated_requests,
          COUNT(*) FILTER (WHERE estimate_status='missing_rates') AS missing_rate_requests,
          COUNT(*) FILTER (WHERE estimate_status='missing_usage') AS missing_usage_requests,
          COUNT(*) FILTER (WHERE estimate_status='unknown') AS unknown_requests"""


def _rows(db, sql: str, params: tuple) -> list[dict[str, Any]]:
    out = []
    for row in db.execute(sql, params).fetchall():
        item = dict(row)
        for key in ("requests", "errors", "input_tokens", "output_tokens", "unsplit_tokens"):
            if key in item:
                item[key] = int(item[key] or 0)
        if "cost_usd" in item:
            item["cost_usd"] = float(item["cost_usd"] or 0)
        out.append(item)
    return out


@dataclass(frozen=True)
class CostWindow:
    first_day: str
    last_day: str
    company: str | None = None
    failed_only: bool = False

    def predicate(self) -> tuple[str, tuple]:
        conditions = ["day BETWEEN ? AND ?"]
        values = [self.first_day, self.last_day]
        if self.company is not None:
            conditions.append("company=?")
            values.append(self.company)
        if self.failed_only:
            conditions.append("ok=0")
        return " AND ".join(conditions), tuple(values)


def summary(db, window: CostWindow, *, recent: int = 50) -> dict[str, Any]:
    where, params = window.predicate()
    companies = db.execute("SELECT DISTINCT company FROM ai_cost_log WHERE day BETWEEN ? AND ? ORDER BY company",
                           (window.first_day, window.last_day))
    return {
        "companies": [row[0] for row in companies],
        "through_id": str(db.execute("SELECT COALESCE(MAX(id),0) FROM ai_cost_log").fetchone()[0]),
        "totals": _rows(db, f"SELECT {SUMS} FROM ai_cost_log WHERE {where}", params)[0],
        "by_company": _rows(db, f"""SELECT company, {SUMS}, COUNT(DISTINCT account_email) AS accounts FROM ai_cost_log
                                    WHERE {where} GROUP BY company ORDER BY cost_usd DESC, requests DESC, company""", params),
        "by_company_model": _rows(db, f"""SELECT company, account_email, provider, model_id, MAX(model_name) AS model_name,
                                          capability, {SUMS} FROM ai_cost_log WHERE {where}
                                          GROUP BY company, account_email, provider, model_id, capability
                                          ORDER BY company, cost_usd DESC, requests DESC, account_email, provider, model_id, capability
                                          LIMIT 500""", params),
        "by_provider_model": _rows(db, f"""SELECT provider, model_id, MAX(model_name) AS model_name, {SUMS}
                                           FROM ai_cost_log WHERE {where} GROUP BY provider, model_id
                                           ORDER BY cost_usd DESC, requests DESC, provider, model_id""", params),
        "by_month": _rows(db, f"""SELECT substr(day,1,7) AS month, company, {SUMS} FROM ai_cost_log WHERE {where}
                                  GROUP BY month, company ORDER BY month DESC, cost_usd DESC, company LIMIT 240""", params),
        "recent": _rows(db, f"""SELECT at, account_email, company, capability, provider, model_id, model_name, ok, http_status,
                                       latency_ms, input_tokens, output_tokens, unsplit_tokens, ROUND(cost_usd, 6) AS cost_usd, estimate_status
                                FROM ai_cost_log WHERE {where} ORDER BY id DESC LIMIT ?""", (*params, recent)),
    }


CSV_COLUMNS = ("at", "company", "account_email", "capability", "provider", "model_id", "model_name", "ok",
               "http_status", "latency_ms", "input_tokens", "output_tokens", "cost_usd", "estimate_status", "unsplit_tokens")


def csv_rows(db, window: CostWindow, through_id: int | None = None):
    where, params = window.predicate()
    if through_id is not None:
        where += " AND id <= ?"
        params = (*params, through_id)
    return db.execute(f"SELECT {','.join(CSV_COLUMNS)} FROM ai_cost_log WHERE {where} ORDER BY id", params)
