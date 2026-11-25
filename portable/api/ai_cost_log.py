"""One row per AI provider call: who asked, for what, which provider and model, tokens and cost.

No prompt or answer text is stored. The caller's account comes from the sign-in check that guards
every AI route (access.require_entitlement / require_admin_session), passed down in a context variable.
Until the workspace has companies of its own, the company is the account's email domain.
"""
from contextvars import ContextVar
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


def set_actor(user: dict[str, Any] | None) -> None:
    """Remember who is signed in for AI calls made while serving this request."""
    email = (user or {}).get("email")
    _actor.set(email.strip().casefold() if isinstance(email, str) and email.strip() else None)


def company_of(email: str | None) -> str:
    if not email or "@" not in email:
        return LOCAL
    return email.rsplit("@", 1)[1]


def record(db, target, *, ok: bool, http_status: int | None, latency_ms: int | None,
           input_tokens: int, output_tokens: int) -> None:
    now = datetime.now(timezone.utc)
    day = now.date().isoformat()
    if _pruned_day[0] != day:
        db.execute("DELETE FROM ai_cost_log WHERE day<?", ((now.date() - timedelta(days=KEEP_DAYS)).isoformat(),))
        _pruned_day[0] = day
    in_tok, out_tok = model_budgets.clamp_tokens(input_tokens), model_budgets.clamp_tokens(output_tokens)
    email = _actor.get()
    db.execute(
        """INSERT INTO ai_cost_log(at,day,account_email,company,capability,provider,model_id,model_name,model_slug,
                                   ok,http_status,latency_ms,input_tokens,output_tokens,cost_usd)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (now.isoformat().replace("+00:00", "Z"), day, email, company_of(email), target.capability, target.provider,
         target.model_id, target.display_name or "", target.slug, 1 if ok else 0, http_status, latency_ms,
         in_tok, out_tok, model_budgets.estimate_cost_usd(in_tok, out_tok, target.config)),
    )


SUMS = """COUNT(*) AS requests, SUM(1-ok) AS errors, SUM(input_tokens) AS input_tokens,
          SUM(output_tokens) AS output_tokens, ROUND(SUM(cost_usd), 6) AS cost_usd"""


def _rows(db, sql: str, params: tuple) -> list[dict[str, Any]]:
    out = []
    for row in db.execute(sql, params).fetchall():
        item = dict(row)
        for key in ("requests", "errors", "input_tokens", "output_tokens"):
            if key in item:
                item[key] = int(item[key] or 0)
        if "cost_usd" in item:
            item["cost_usd"] = float(item["cost_usd"] or 0)
        out.append(item)
    return out


def summary(db, first_day: str, *, recent: int = 50) -> dict[str, Any]:
    window = (first_day,)
    return {
        "totals": _rows(db, f"SELECT {SUMS} FROM ai_cost_log WHERE day>=?", window)[0],
        "by_company": _rows(db, f"""SELECT company, {SUMS}, COUNT(DISTINCT account_email) AS accounts FROM ai_cost_log
                                    WHERE day>=? GROUP BY company ORDER BY cost_usd DESC, requests DESC""", window),
        "by_company_model": _rows(db, f"""SELECT company, account_email, provider, model_id, model_name, capability, {SUMS}
                                          FROM ai_cost_log WHERE day>=?
                                          GROUP BY company, account_email, provider, model_id, capability
                                          ORDER BY company, cost_usd DESC, requests DESC LIMIT 500""", window),
        "by_provider_model": _rows(db, f"""SELECT provider, model_id, model_name, {SUMS} FROM ai_cost_log
                                           WHERE day>=? GROUP BY provider, model_id ORDER BY cost_usd DESC, requests DESC""", window),
        "by_month": _rows(db, f"""SELECT substr(day,1,7) AS month, company, {SUMS} FROM ai_cost_log
                                  GROUP BY month, company ORDER BY month DESC, cost_usd DESC LIMIT 240""", ()),
        "recent": _rows(db, """SELECT at, account_email, company, capability, provider, model_id, model_name, ok, http_status,
                                      latency_ms, input_tokens, output_tokens, ROUND(cost_usd, 6) AS cost_usd
                               FROM ai_cost_log WHERE day>=? ORDER BY id DESC LIMIT ?""", (first_day, recent)),
    }


CSV_COLUMNS = ("at", "company", "account_email", "capability", "provider", "model_id", "model_name", "ok",
               "http_status", "latency_ms", "input_tokens", "output_tokens", "cost_usd")


def csv_rows(db, first_day: str, limit: int = 100_000):
    return db.execute(f"SELECT {','.join(CSV_COLUMNS)} FROM ai_cost_log WHERE day>=? ORDER BY id LIMIT ?",
                      (first_day, limit)).fetchall()
