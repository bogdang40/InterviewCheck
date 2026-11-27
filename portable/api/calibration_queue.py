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
        f"""SELECT e.answer_id, COALESCE(c.role_id, e.role_id) AS role_id,
                   e.reviewer_id, e.reviewer_email, e.disposition, e.created_at
            FROM answer_review_events e
            JOIN active_sessions s ON s.id = e.session_id
            JOIN answers a ON a.id = e.answer_id AND a.session_id = s.id
            LEFT JOIN session_context c ON c.session_id = s.id
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

    states = {}
    if panel_view == "all":
        times = panel_ledger.decision_times(db, latest)
    else:
        states = panel_ledger.queue_states(db, latest, generations) if panel_view else {}
        times = {aid: at for aid, (_, at) in states.items()}

    active_reviewers, role_ids_with_disagreements = set(), set()
    ranked = []
    splits = 0
    for answer_id, by_reviewer in latest.items():
        rev_rows = [r for r in by_reviewer.values() if r["disposition"] != "pending"]
        active_reviewers.update(r["reviewer_id"] for r in rev_rows)
        if len({r["disposition"] for r in rev_rows}) > 1:
            splits += 1
            role = next(iter(by_reviewer.values()))["role_id"]
            if role:
                role_ids_with_disagreements.add(role)
        elif answer_id not in times:
            continue
        if panel_view in ("open", "completed"):
            completed = states.get(answer_id, ("open", ""))[0] == "discussion_complete"
            if completed != (panel_view == "completed"):
                continue
        # A pending vote contributes to panel order but not to the legacy disagreement export.
        vote_time = max(r["created_at"] for r in (by_reviewer.values() if panel_view else rev_rows))
        ranked.append((max(vote_time, times.get(answer_id, "")), answer_id))
    ranked.sort(reverse=True)

    summary = {
        "roles_with_disagreements": len(role_ids_with_disagreements),
        "total_disagreed_answers": splits,
        "reviewer_count": len(active_reviewers),
    }
    offset = 0
    result = {"summary": summary}
    if panel_view:
        total = len(ranked)
        actual_page = min(page, max(1, (total + limit - 1) // limit))
        offset = (actual_page - 1) * limit
        result.update(matching_cases=total, page=actual_page)
    ids = [aid for _, aid in ranked[offset:offset + limit]]
    if panel_view == "all":
        states = panel_ledger.queue_states(db, latest, generations, answer_ids=(aid for aid in ids if aid in times))
    result["items"] = _page_items(db, ids, latest, states, panel_view)
    return result


def _page_items(db, ids, latest, states, panel_view):
    # Preserve each case's selected role even when an old review has only its event role ID.
    if not ids:
        return []
    keys = [(aid, next(iter(latest[aid].values()))["role_id"]) for aid in ids]
    rows = db.execute("""SELECT a.id AS answer_id,a.session_id,a.question,a.disposition AS current_disposition,
                               s.candidate,json_extract(k.value,'$[1]') AS role_id,COALESCE(r.name,s.role) AS role_name
                        FROM json_each(?) k JOIN answers a ON a.id=json_extract(k.value,'$[0]')
                        JOIN active_sessions s ON s.id=a.session_id LEFT JOIN roles r ON r.id=json_extract(k.value,'$[1]')
                        ORDER BY k.key""", (json.dumps(keys),))
    items = []
    for row in rows:
        aid = row["answer_id"]
        reviews = sorted((r for r in latest[aid].values() if r["disposition"] != "pending"),
                         key=lambda r: (r["created_at"], r["reviewer_email"].casefold(), r["reviewer_id"]))
        item = dict(row)
        item["reviewers"] = [{"reviewer_email": r["reviewer_email"], "disposition": r["disposition"],
                              "created_at": r["created_at"]} for r in reviews]
        if panel_view:
            item["panel_status"] = states.get(aid, ("open", ""))[0]
        items.append(item)
    return items


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
