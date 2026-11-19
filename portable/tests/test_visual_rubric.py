"""Unit tests for visual_rubric mobile table failure detection and aggregation."""
from __future__ import annotations

from qa.visual_rubric import AUDIT_JS, record_passes_rubric, summarize_records


def _clean_record(**overrides) -> dict:
    record = {
        "scrollWidth": 390,
        "clientWidth": 390,
        "overflow": False,
        "clipped_count": 0,
        "clipped": [],
        "overlap_count": 0,
        "overlaps": [],
        "touch_target_failures": [],
        "table_failures": [],
        "contrast": {
            "ink_on_surface": 12.5,
            "muted_on_surface": 5.2,
            "secondary_on_surface": 5.8,
            "green_ink_on_selected": 6.1,
            "error_on_error_bg": 5.4,
            "attention_on_warning_bg": 5.0,
            "input_border_on_surface": 3.8,
            "heading_ratio": 12.5,
            "body_ratio": 12.5,
            "control_border_min": 4.1,
            "control_border_failures": [],
        },
        "console_errors": [],
        "page_errors": [],
        "server_errors": [],
        "csp_violations": [],
    }
    record.update(overrides)
    return record


def test_clean_record_with_empty_table_failures_passes():
    rec = _clean_record(table_failures=[])
    assert record_passes_rubric(rec) == []
    summary = summarize_records([rec])
    assert summary["table_failures"] == 0
    assert summary["passed"] is True


def test_table_failures_fail_closed_in_record_and_summary():
    bad = _clean_record(
        table_failures=[
            {"caption": "Cohort candidate pipeline", "reason": "squished_columns", "cols": 8, "minCellWidth": 42.0}
        ]
    )
    reasons = record_passes_rubric(bad)
    assert len(reasons) == 1
    assert "mobile table overflow/squish (1)" in reasons

    summary = summarize_records([_clean_record(), bad])
    assert summary["total_screenshots"] == 2
    assert summary["table_failures"] == 1
    assert summary["passed"] is False


def test_audit_js_contains_mobile_table_and_clipped_thead_guards():
    assert "table_failures: tableFailures" in AUDIT_JS
    assert "inner_overflow" in AUDIT_JS
    assert "squished_columns" in AUDIT_JS
    assert 'clipPath === "inset(50%)"' in AUDIT_JS
