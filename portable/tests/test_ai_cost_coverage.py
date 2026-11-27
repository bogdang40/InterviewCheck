"""Verify estimate coverage on retained and newly measured provider attempts."""
from contextlib import closing
from datetime import datetime, timezone
import sqlite3
from types import SimpleNamespace

import pytest

from api import ai_cost_log, model_budgets


@pytest.mark.parametrize(("capability", "counts", "expected"), [
    ("judge", {"input_tokens": 0, "output_tokens": 0}, True),
    ("judge", {"prompt_tokens": 2, "completion_tokens": 1, "total_tokens": 3}, True),
    ("judge", {"total_tokens": 3}, False),
    ("judge", {"prompt_tokens": 2}, False),
    ("judge", {"input_tokens": True, "output_tokens": 0}, False),
    ("judge", {"input_tokens": -1, "output_tokens": 0}, False),
    ("judge", {"input_tokens": 1, "output_tokens": 2, "total_tokens": 10}, False),
    ("embedding", {"prompt_tokens": 2, "total_tokens": 2}, True),
    ("embedding", {"total_tokens": 0}, True),
    ("embedding", {}, False),
])
def test_required_usage_evidence_depends_on_capability(capability, counts, expected):
    usage = model_budgets.provider_usage("openai", {"usage": counts}, capability=capability)
    assert usage.complete is expected


def test_retained_row_and_new_estimates_keep_their_recorded_coverage():
    today = datetime.now(timezone.utc).date().isoformat()
    window = ai_cost_log.CostWindow(today, today)
    with closing(sqlite3.connect(":memory:")) as db:
        db.row_factory = sqlite3.Row
        # These are the columns on the previous release. The amount cannot recover its original rates.
        db.execute("""CREATE TABLE ai_cost_log (
            id INTEGER PRIMARY KEY, at TEXT, day TEXT, account_email TEXT, company TEXT DEFAULT '',
            capability TEXT, provider TEXT, model_id TEXT, model_name TEXT DEFAULT '', model_slug TEXT,
            ok INTEGER, http_status INTEGER, latency_ms INTEGER, input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0, cost_usd REAL DEFAULT 0
        )""")
        db.execute("""INSERT INTO ai_cost_log (at,day,capability,provider,model_id,ok,cost_usd)
                      VALUES (?,?,'judge','openai','example',1,0.5)""", (today, today))
        ai_cost_log.migrate(db)
        target = SimpleNamespace(capability="judge", provider="openai", model_id="example",
                                 display_name="", slug=None, config={"input_cost_per_1m_usd": 2})
        complete = model_budgets.TokenUsage(1_000_000, 100, True)
        ai_cost_log.record(db, target, ok=True, http_status=200, latency_ms=5, usage=complete)
        target.config["output_cost_per_1m_usd"] = 0
        ai_cost_log.record(db, target, ok=True, http_status=200, latency_ms=5, usage=complete)
        ai_cost_log.record(db, target, ok=False, http_status=503, latency_ms=5, usage=model_budgets.TokenUsage())
        ai_cost_log.migrate(db)
        report = ai_cost_log.summary(db, window)
        for group in ("by_company", "by_company_model", "by_month", "by_provider_model"):
            for key in ("estimated_requests", "missing_rate_requests", "missing_usage_requests", "unknown_requests"):
                assert sum(row[key] for row in report[group]) == report["totals"][key] == 1
        assert report["totals"]["cost_usd"] == 4.5
        statuses = ["unknown", "missing_rates", "estimated", "missing_usage"]
        assert [row["estimate_status"] for row in reversed(report["recent"])] == statuses
        assert ai_cost_log.CSV_COLUMNS[-3:] == ("cost_usd", "estimate_status", "unsplit_tokens")
        assert [row["estimate_status"] for row in ai_cost_log.csv_rows(db, window)] == statuses


def test_existing_daily_budget_keeps_its_usage_after_unsplit_counter_upgrade():
    with closing(sqlite3.connect(":memory:")) as db:
        db.row_factory = sqlite3.Row
        db.execute("""CREATE TABLE model_usage_daily (
            model_id TEXT, usage_date TEXT, request_count INTEGER, error_count INTEGER, input_tokens INTEGER,
            output_tokens INTEGER, estimated_cost_usd REAL, updated_at TEXT, PRIMARY KEY (model_id, usage_date)
        )""")
        day = "2026-11-26"
        db.execute("INSERT INTO model_usage_daily VALUES ('model',?,1,0,7,3,0.25,?)", (day, day))
        model_budgets.migrate(db)
        model_budgets.migrate(db)
        model_budgets.record_usage(db, "model", input_tokens=0, output_tokens=0, unsplit_tokens=50,
                                   config={}, ok=True, usage_date=day)
        decision = model_budgets.check_budget(db, "model", {"daily_token_limit": 60}, today=day)
        assert decision.daily_tokens == 60 and decision.monthly_cost_usd == 0.25
        assert decision.reason == "daily_token_limit_exceeded"
