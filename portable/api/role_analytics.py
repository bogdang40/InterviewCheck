"""Multi-reviewer calibration tracking and role-level review analytics."""
from collections import defaultdict
from datetime import datetime, timezone
import sqlite3
from typing import Any
from uuid import UUID

from fastapi import APIRouter, HTTPException

from . import sql_script

router = APIRouter()

SCHEMA = """
CREATE TABLE IF NOT EXISTS answer_review_events (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 answer_id TEXT NOT NULL REFERENCES answers(id) ON DELETE CASCADE,
 role_id TEXT,
 reviewer_id TEXT NOT NULL,
 reviewer_email TEXT NOT NULL,
 previous_disposition TEXT NOT NULL,
 disposition TEXT NOT NULL CHECK(disposition IN ('pending','explained','unresolved','disclosed')),
 created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_review_events_role ON answer_review_events(role_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_review_events_answer ON answer_review_events(answer_id, id DESC);
"""


def migrate(db: sqlite3.Connection) -> None:
    sql_script.execute(db, SCHEMA)


def latest_reviewer_disposition(db: sqlite3.Connection, answer_id: str, reviewer_id: str) -> str | None:
    row = db.execute(
        "SELECT disposition FROM answer_review_events WHERE answer_id=? AND reviewer_id=? ORDER BY id DESC LIMIT 1",
        (answer_id, reviewer_id),
    ).fetchone()
    return row["disposition"] if row is not None else None


def record_review_event(
    db: sqlite3.Connection,
    *,
    session_id: str,
    answer_id: str,
    reviewer_id: str,
    reviewer_email: str,
    previous_disposition: str,
    disposition: str,
) -> None:
    ctx = db.execute("SELECT role_id FROM session_context WHERE session_id=?", (session_id,)).fetchone()
    role_id = ctx["role_id"] if ctx is not None else None
    db.execute(
        """INSERT INTO answer_review_events(
               session_id, answer_id, role_id, reviewer_id, reviewer_email,
               previous_disposition, disposition, created_at
           ) VALUES (?,?,?,?,?,?,?,?)""",
        (session_id, answer_id, role_id, reviewer_id, reviewer_email, previous_disposition, disposition,
         datetime.now(timezone.utc).isoformat()),
    )


def _pct(part: int, total: int) -> float:
    return round(part * 100.0 / total, 1) if total else 0.0


def _summarize_events(
    event_rows: list[sqlite3.Row], baseline_pass_rate: float, has_reviewed: bool
) -> tuple[int, list[dict[str, Any]], dict[str, dict[str, dict[str, Any]]]]:
    latest_per_pair: dict[tuple[str, str], sqlite3.Row] = {}
    for row in event_rows:
        latest_per_pair[(row["answer_id"], row["reviewer_id"])] = row

    by_answer: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    by_reviewer: dict[str, dict[str, Any]] = {}
    for (answer_id, reviewer_id), row in latest_per_pair.items():
        disp = row["disposition"]
        if disp == "pending":
            continue
        by_answer[answer_id][reviewer_id] = {
            "reviewer_id": reviewer_id,
            "reviewer_email": row["reviewer_email"],
            "disposition": disp,
            "created_at": row["created_at"],
        }
        bucket = by_reviewer.setdefault(
            reviewer_id,
            {"reviewer_id": reviewer_id, "reviewer_email": row["reviewer_email"],
             "explained_count": 0, "unresolved_count": 0, "disclosed_count": 0},
        )
        bucket["reviewer_email"] = row["reviewer_email"]
        bucket[f"{disp}_count"] += 1

    disagreed = {
        aid: reviewers for aid, reviewers in by_answer.items()
        if len({entry["disposition"] for entry in reviewers.values()}) >= 2
    }
    reviewers_out: list[dict[str, Any]] = []
    for bucket in by_reviewer.values():
        explained = bucket["explained_count"]
        concern = bucket["unresolved_count"] + bucket["disclosed_count"]
        total = explained + concern
        pass_rate = _pct(explained, total)
        reviewers_out.append({
            "reviewer_id": bucket["reviewer_id"],
            "reviewer_email": bucket["reviewer_email"],
            "total_reviews": total,
            "explained_count": explained,
            "unresolved_count": bucket["unresolved_count"],
            "disclosed_count": bucket["disclosed_count"],
            "concern_count": concern,
            "pass_rate_pct": pass_rate,
            "concern_rate_pct": _pct(concern, total),
            "delta_vs_baseline_pp": round(pass_rate - baseline_pass_rate, 1) if has_reviewed else 0.0,
        })
    reviewers_out.sort(key=lambda item: (-item["total_reviews"], item["reviewer_email"].casefold(), item["reviewer_id"]))
    return len(disagreed), reviewers_out, disagreed


def _compute_metrics(
    session_rows: list[sqlite3.Row], answer_rows: list[sqlite3.Row], event_rows: list[sqlite3.Row]
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, dict[str, dict[str, Any]]]]:
    answer_count = len(answer_rows)
    match_count = sum(1 for r in answer_rows if r["status"] == "match")
    explained_count = sum(1 for r in answer_rows if r["disposition"] == "explained")
    unresolved_count = sum(1 for r in answer_rows if r["disposition"] == "unresolved")
    disclosed_count = sum(1 for r in answer_rows if r["disposition"] == "disclosed")
    concern_count = unresolved_count + disclosed_count
    reviewed_count = explained_count + concern_count
    pass_rate = _pct(explained_count, reviewed_count)
    disagreements, reviewer_summary, disagreed_map = _summarize_events(event_rows, pass_rate, reviewed_count > 0)
    metrics = {
        "session_count": len(session_rows),
        "finished_count": sum(1 for r in session_rows if r["ended_at"] is not None),
        "answer_count": answer_count,
        "match_count": match_count,
        "no_match_count": sum(1 for r in answer_rows if r["status"] == "no_match"),
        "insufficient_count": sum(1 for r in answer_rows if r["status"] == "insufficient"),
        "match_rate_pct": _pct(match_count, answer_count),
        "explained_count": explained_count,
        "unresolved_count": unresolved_count,
        "disclosed_count": disclosed_count,
        "concern_count": concern_count,
        "pending_count": sum(1 for r in answer_rows if r["disposition"] == "pending"),
        "reviewed_count": reviewed_count,
        "pass_rate_pct": pass_rate,
        "concern_rate_pct": _pct(concern_count, reviewed_count),
        "multi_reviewer_disagreements": disagreements,
    }
    return metrics, reviewer_summary, disagreed_map


@router.get("/roles/analytics")
def roles_analytics():
    from . import store

    with store.connection() as db:
        role_rows = db.execute("SELECT id, name, version_number FROM roles ORDER BY name COLLATE NOCASE, id").fetchall()
        session_rows = db.execute(
            "SELECT s.id, c.role_id, c.ended_at FROM active_sessions s LEFT JOIN session_context c ON c.session_id=s.id"
        ).fetchall()
        answer_rows = db.execute(
            """SELECT a.id, a.session_id, a.status, a.disposition, c.role_id
               FROM answers a JOIN active_sessions s ON s.id=a.session_id
               LEFT JOIN session_context c ON c.session_id=s.id"""
        ).fetchall()
        event_rows = db.execute(
            """SELECT e.id, e.session_id, e.answer_id, COALESCE(c.role_id, e.role_id) AS role_id,
                      e.reviewer_id, e.reviewer_email, e.disposition, e.created_at
               FROM answer_review_events e JOIN active_sessions s ON s.id=e.session_id
               LEFT JOIN session_context c ON c.session_id=e.session_id ORDER BY e.id ASC"""
        ).fetchall()

    sessions_by_role: dict[str | None, list[sqlite3.Row]] = defaultdict(list)
    answers_by_role: dict[str | None, list[sqlite3.Row]] = defaultdict(list)
    events_by_role: dict[str | None, list[sqlite3.Row]] = defaultdict(list)
    for row in session_rows:
        sessions_by_role[row["role_id"]].append(row)
    for row in answer_rows:
        answers_by_role[row["role_id"]].append(row)
    for row in event_rows:
        events_by_role[row["role_id"]].append(row)

    per_role = []
    for role in role_rows:
        rid = role["id"]
        metrics, reviewers, _ = _compute_metrics(sessions_by_role[rid], answers_by_role[rid], events_by_role[rid])
        per_role.append({
            "role_id": rid,
            "role_name": role["name"],
            "version_number": int(role["version_number"]),
            **metrics,
            "reviewer_summary": reviewers,
        })
    totals, global_reviewers, _ = _compute_metrics(session_rows, answer_rows, event_rows)
    return {"roles": per_role, "totals": {"role_count": len(role_rows), **totals}, "reviewer_summary": global_reviewers}


@router.get("/roles/{rid}/calibration")
def role_calibration(rid: UUID):
    from . import store

    key = str(rid)
    with store.connection() as db:
        role = db.execute("SELECT id, name, version_number FROM roles WHERE id=?", (key,)).fetchone()
        if role is None:
            raise HTTPException(404, "Role does not exist.")
        session_rows = db.execute(
            "SELECT s.id, c.ended_at FROM active_sessions s JOIN session_context c ON c.session_id=s.id WHERE c.role_id=?",
            (key,),
        ).fetchall()
        answer_rows = db.execute(
            """SELECT a.id, a.session_id, a.question, a.planned_slot, a.status, a.disposition
               FROM answers a JOIN active_sessions s ON s.id=a.session_id
               JOIN session_context c ON c.session_id=s.id WHERE c.role_id=? ORDER BY a.rowid ASC""",
            (key,),
        ).fetchall()
        event_rows = db.execute(
            """SELECT e.id, e.session_id, e.answer_id, e.reviewer_id, e.reviewer_email, e.disposition, e.created_at
               FROM answer_review_events e JOIN active_sessions s ON s.id=e.session_id
               JOIN session_context c ON c.session_id=e.session_id WHERE c.role_id=? ORDER BY e.id ASC""",
            (key,),
        ).fetchall()

    summary, reviewers, disagreed_map = _compute_metrics(session_rows, answer_rows, event_rows)
    by_slot: dict[tuple[bool, int, str], list[sqlite3.Row]] = defaultdict(list)
    answers_by_id = {row["id"]: row for row in answer_rows}
    for row in answer_rows:
        slot = row["planned_slot"]
        by_slot[(slot is None, int(slot) if slot is not None else 0, row["question"] if slot is None else "")].append(row)

    question_breakdown = []
    for (no_slot, slot_num, _), rows in sorted(
        by_slot.items(), key=lambda item: (item[0][0], item[0][1], item[1][0]["question"].casefold())
    ):
        slot_ids = {r["id"] for r in rows}
        slot_metrics, _, _ = _compute_metrics([], rows, [e for e in event_rows if e["answer_id"] in slot_ids])
        question_breakdown.append({
            "planned_slot": None if no_slot else slot_num,
            "question": rows[0]["question"],
            **{k: slot_metrics[k] for k in (
                "answer_count", "match_count", "no_match_count", "insufficient_count", "match_rate_pct",
                "explained_count", "unresolved_count", "disclosed_count", "concern_count", "pending_count",
                "pass_rate_pct", "concern_rate_pct",
            )},
            "disagreement_count": slot_metrics["multi_reviewer_disagreements"],
        })

    disagreements_out = []
    for aid, rev_map in list(disagreed_map.items())[-50:]:
        ans = answers_by_id.get(aid)
        if ans is not None:
            disagreements_out.append({
                "answer_id": aid,
                "session_id": ans["session_id"],
                "question": ans["question"],
                "planned_slot": ans["planned_slot"],
                "current_disposition": ans["disposition"],
                "reviewers": sorted(rev_map.values(), key=lambda item: item["created_at"]),
            })

    return {
        "role_id": role["id"],
        "role_name": role["name"],
        "version_number": int(role["version_number"]),
        "summary": summary,
        "question_breakdown": question_breakdown,
        "reviewer_summary": reviewers,
        "disagreements": disagreements_out,
    }
