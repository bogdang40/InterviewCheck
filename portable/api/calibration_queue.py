"""Cross-role reviewer calibration disagreement queue and CSV/JSON export."""
from collections import Counter, defaultdict
import json
import sqlite3
from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, Query, Response

from . import exports, panel_ledger, role_analytics, session_privacy, store

PanelView = Literal["all", "open", "completed"]
router = APIRouter(tags=["calibration"])
_NO_STORE = {"Cache-Control": "no-store"}


def _has_table(db: sqlite3.Connection, name: str, *, include_views: bool = False) -> bool:
    kind = "type IN ('table','view')" if include_views else "type='table'"
    return db.execute(f"SELECT 1 FROM sqlite_master WHERE {kind} AND name=?", (name,)).fetchone() is not None


def _collect_disagreements(
    db: sqlite3.Connection,
    *,
    role_id: UUID | None,
    limit: int,
    panel_view: PanelView | None = None,
    page: int = 1,
) -> dict[str, Any]:
    empty_summary = {"roles_with_disagreements": 0, "total_disagreed_answers": 0, "reviewer_count": 0}
    required_tables = ("answers", "session_context", "roles", "answer_review_events")
    if not _has_table(db, "active_sessions", include_views=True) or any(not _has_table(db, t) for t in required_tables):
        return {"summary": empty_summary, "items": [], **({"matching_cases": 0, "page": 1} if panel_view else {})}

    anon_clause = session_privacy.calibration_filter(db)
    role_clause = "AND COALESCE(c.role_id, e.role_id) = ?" if role_id is not None else ""
    params: tuple[Any, ...] = (str(role_id),) if role_id is not None else ()

    rows = db.execute(
        f"""SELECT e.id, e.session_id, e.answer_id, COALESCE(c.role_id, e.role_id) AS role_id,
                   e.reviewer_id, e.reviewer_email, e.disposition, e.created_at,
                   a.question AS question, a.disposition AS current_disposition,
                   s.candidate AS candidate, COALESCE(r.name, s.role) AS role_name
            FROM answer_review_events e
            JOIN active_sessions s ON s.id = e.session_id
            JOIN answers a ON a.id = e.answer_id AND a.session_id = s.id
            LEFT JOIN session_context c ON c.session_id = s.id
            LEFT JOIN roles r ON r.id = COALESCE(c.role_id, e.role_id)
            WHERE 1=1 {anon_clause} {role_clause}
            ORDER BY e.id ASC""",
        params,
    )
    latest = defaultdict(dict)
    generations = defaultdict(Counter)
    for row in rows:
        aid, uid = row["answer_id"], row["reviewer_id"]
        latest[aid][uid] = row
        generations[aid][uid] += 1

    states = panel_ledger.queue_states(db, latest, generations) if panel_view else {}
    active_reviewers, role_ids_with_disagreements = set(), set()
    disagreed_items = []
    splits = 0
    for answer_id, by_reviewer in latest.items():
        first = next(iter(by_reviewer.values()))
        rev_rows = [r for r in by_reviewer.values() if r["disposition"] != "pending"]
        active_reviewers.update(r["reviewer_id"] for r in rev_rows)
        split = len({r["disposition"] for r in rev_rows}) > 1
        if split:
            splits += 1
            if first["role_id"]:
                role_ids_with_disagreements.add(first["role_id"])
        elif answer_id not in states:
            continue
        panel_status, decision_at = states.get(answer_id, ("open", ""))
        if panel_view == "open" and panel_status == "discussion_complete":
            continue
        if panel_view == "completed" and panel_status != "discussion_complete":
            continue
        ordered = sorted(rev_rows, key=lambda r: (r["created_at"], r["reviewer_email"].casefold(), r["reviewer_id"]))
        item = {"_latest_ts": max(decision_at, *(r["created_at"] for r in (by_reviewer.values() if panel_view else ordered))),
                "role_id": first["role_id"], "role_name": first["role_name"], "session_id": first["session_id"],
                "candidate": first["candidate"], "answer_id": answer_id, "question": first["question"],
                "current_disposition": first["current_disposition"],
                "reviewers": [{"reviewer_email": r["reviewer_email"], "disposition": r["disposition"],
                               "created_at": r["created_at"]} for r in ordered]}
        if panel_view:
            item["panel_status"] = panel_status
        disagreed_items.append(item)

    disagreed_items.sort(key=lambda item: (item["_latest_ts"], item["answer_id"]), reverse=True)
    for item in disagreed_items:
        item.pop("_latest_ts", None)

    summary = {
        "roles_with_disagreements": len(role_ids_with_disagreements),
        "total_disagreed_answers": splits,
        "reviewer_count": len(active_reviewers),
    }
    offset = 0
    result = {"summary": summary}
    if panel_view:
        total = len(disagreed_items)
        actual_page = min(page, max(1, (total + limit - 1) // limit))
        offset = (actual_page - 1) * limit
        result.update(matching_cases=total, page=actual_page)
    result["items"] = disagreed_items[offset:offset + limit]
    return result


def _collect_reviewer_metrics(has_events: bool, *, role_id: UUID | None) -> list[dict[str, Any]]:
    if not has_events:
        return []
    analytics = role_analytics.roles_analytics()
    metrics_rows: list[dict[str, Any]] = []
    target_rid = str(role_id) if role_id is not None else None
    for role_entry in analytics.get("roles", []):
        if target_rid is not None and role_entry["role_id"] != target_rid:
            continue
        for reviewer in role_entry.get("reviewer_summary", []):
            metrics_rows.append(
                {
                    "role_id": role_entry["role_id"],
                    "role_name": role_entry["role_name"],
                    **reviewer,
                }
            )
    return metrics_rows


@router.get("/calibration/disagreements")
def calibration_disagreements(
    role_id: UUID | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    panel_view: PanelView | None = None,
    page: int = Query(default=1, ge=1, le=2**31-1),
):
    with store.connection() as db:
        return _collect_disagreements(db, role_id=role_id, limit=limit, panel_view=panel_view, page=page)


@router.get("/calibration/export")
def export_calibration(
    role_id: UUID | None = None,
    format: Literal["csv", "json"] = "csv",
):
    with store.connection() as db:
        queue = _collect_disagreements(db, role_id=role_id, limit=2000)
        has_events = _has_table(db, "answer_review_events")
    reviewer_metrics = _collect_reviewer_metrics(has_events, role_id=role_id)

    if format == "json":
        payload = {
            "exported_at": store.timestamp(),
            "role_id": str(role_id) if role_id else None,
            "summary": queue["summary"],
            "reviewer_metrics": reviewer_metrics,
            "disagreements": queue["items"],
        }
        return Response(
            json.dumps(payload, indent=2, ensure_ascii=False),
            media_type="application/json; charset=utf-8",
            headers={"Content-Disposition": 'attachment; filename="calibration-queue.json"', **_NO_STORE},
        )

    header = [
        "Record Type",
        "Role ID",
        "Role Name",
        "Reviewer Email",
        "Total Reviews",
        "Explained",
        "Unresolved",
        "Disclosed",
        "Pass Rate Pct",
        "Concern Rate Pct",
        "Delta vs Baseline PP",
        "Session ID",
        "Candidate",
        "Answer ID",
        "Question",
        "Current Disposition",
        "Reviewer Dispositions",
    ]
    lines = ["\ufeff" + exports.csv_row(header)]
    for m in reviewer_metrics:
        lines.append(
            exports.csv_row(
                [
                    "reviewer_metric",
                    m["role_id"],
                    m["role_name"],
                    m["reviewer_email"],
                    m["total_reviews"],
                    m["explained_count"],
                    m["unresolved_count"],
                    m["disclosed_count"],
                    m["pass_rate_pct"],
                    m["concern_rate_pct"],
                    m["delta_vs_baseline_pp"],
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                ]
            )
        )
    for item in queue["items"]:
        disp_summary = "; ".join(f"{r['reviewer_email']}: {r['disposition']}" for r in item["reviewers"])
        lines.append(
            exports.csv_row(
                [
                    "disagreement",
                    item["role_id"],
                    item["role_name"],
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    item["session_id"],
                    item["candidate"],
                    item["answer_id"],
                    item["question"],
                    item["current_disposition"],
                    disp_summary,
                ]
            )
        )
    return Response(
        "".join(lines),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="calibration-queue.csv"', **_NO_STORE},
    )
