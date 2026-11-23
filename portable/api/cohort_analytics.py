"""Cross-role cohort analytics, scorecard calibration histograms, and CSV/JSON exports."""
from collections import defaultdict
from datetime import datetime, timezone
import json
import sqlite3
from tempfile import SpooledTemporaryFile
from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import Response, StreamingResponse
from starlette.background import BackgroundTask

from . import exports, store
from .scorecard_math import percentage_from_totals

router = APIRouter()
LifecycleFilter = Literal["", "active", "finished", "archived"]
ExportFormat = Literal["csv", "json"]

_SCORE_BUCKETS = (
    ("0_20", "0-20%", 0.0, 20.0, False),
    ("20_40", "20-40%", 20.0, 40.0, False),
    ("40_60", "40-60%", 40.0, 60.0, False),
    ("60_80", "60-80%", 60.0, 80.0, False),
    ("80_100", "80-100%", 80.0, 100.0, True),
)
CSV_HEADER = [
    "Session ID", "Candidate", "Role", "Role ID", "Lifecycle", "Created at", "Ended at",
    "Tags", "Answers", "Matched", "Explained", "Concerns", "Pending", "Weighted score %",
]


def _has_table(db: sqlite3.Connection, name: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _require_tz_utc(value: datetime | None, name: str) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None or value.utcoffset() is None:
        raise HTTPException(422, f"{name} timestamp must include a timezone offset.")
    return value.astimezone(timezone.utc)


def _parse_utc(raw: str) -> datetime:
    dt = datetime.fromisoformat(raw)
    return dt.replace(tzinfo=timezone.utc) if (dt.tzinfo is None or dt.utcoffset() is None) else dt.astimezone(timezone.utc)


def _pct(part: int, total: int) -> float:
    return round(part * 100.0 / total, 1) if total else 0.0


def _bucket_key(score_pct: float) -> str:
    for key, _label, low, high, inc in _SCORE_BUCKETS:
        if (low <= score_pct <= high) if inc else (low <= score_pct < high):
            return key
    return "80_100" if score_pct >= 80.0 else "0_20"


def _validate_filters(
    role_id: UUID | None, tag: str, lifecycle: LifecycleFilter, since: datetime | None, until: datetime | None
) -> dict[str, Any]:
    since_utc = _require_tz_utc(since, "since")
    until_utc = _require_tz_utc(until, "until")
    if since_utc is not None and until_utc is not None and since_utc > until_utc:
        raise HTTPException(422, "since must be earlier than or equal to until.")
    return {
        "role_id": str(role_id) if role_id else None,
        "tag": tag.strip(),
        "lifecycle": lifecycle,
        "since": since_utc,
        "until": until_utc,
    }


def _chunks(items: list[str], size: int = 500):
    for idx in range(0, len(items), size):
        chunk = items[idx : idx + size]
        yield chunk, ",".join("?" for _ in chunk)


def _load_session_tags(db: sqlite3.Connection, session_ids: list[str]) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {sid: [] for sid in session_ids}
    if not session_ids or not _has_table(db, "session_tags"):
        return result
    for chunk, ph in _chunks(session_ids):
        for row in db.execute(f"SELECT session_id, tag FROM session_tags WHERE session_id IN ({ph}) ORDER BY tag COLLATE NOCASE ASC, tag ASC", tuple(chunk)):
            result.setdefault(row["session_id"], []).append(row["tag"])
    return result


def _load_scorecard_pcts(db: sqlite3.Connection, session_ids: list[str]) -> dict[str, float]:
    if not session_ids or not _has_table(db, "session_scorecards"):
        return {}
    totals: dict[str, list[int]] = {}
    for chunk, ph in _chunks(session_ids):
        for row in db.execute(f"SELECT session_id, weight, rating FROM session_scorecards WHERE session_id IN ({ph})", tuple(chunk)):
            weight, rating = int(row["weight"]), int(row["rating"])
            if weight > 0 and 1 <= rating <= 5:
                acc = totals.setdefault(row["session_id"], [0, 0])
                acc[0] += rating * weight
                acc[1] += weight
    return {sid: percentage_from_totals(ws, tw) for sid, (ws, tw) in totals.items() if tw > 0}


def _load_answer_counts(db: sqlite3.Connection, session_ids: list[str]) -> dict[str, dict[str, int]]:
    counts = {sid: {"answer_count": 0, "match_count": 0, "explained_count": 0, "concern_count": 0, "pending_count": 0} for sid in session_ids}
    for chunk, ph in _chunks(session_ids):
        rows = db.execute(
            f"""SELECT session_id, COUNT(*) AS answer_count,
                       SUM(CASE WHEN status='match' THEN 1 ELSE 0 END) AS match_count,
                       SUM(CASE WHEN disposition='explained' THEN 1 ELSE 0 END) AS explained_count,
                       SUM(CASE WHEN disposition IN ('unresolved', 'disclosed') THEN 1 ELSE 0 END) AS concern_count,
                       SUM(CASE WHEN disposition='pending' THEN 1 ELSE 0 END) AS pending_count
                FROM answers WHERE session_id IN ({ph}) GROUP BY session_id""",
            tuple(chunk),
        )
        for row in rows:
            counts[row["session_id"]] = {k: int(row[k] or 0) for k in counts[row["session_id"]]}
    return counts


def _query_matching_sessions(db: sqlite3.Connection, parsed: dict[str, Any]) -> list[tuple[sqlite3.Row, datetime]]:
    tag_filter = parsed["tag"]
    if tag_filter and not _has_table(db, "session_tags"):
        return []
    clauses, bind = ["1=1"], {}
    if parsed["role_id"]:
        clauses.append("c.role_id = :role_id")
        bind["role_id"] = parsed["role_id"]
    if parsed["lifecycle"] == "active":
        clauses.append("c.ended_at IS NULL AND s.consent")
    elif parsed["lifecycle"] == "finished":
        clauses.append("c.ended_at IS NOT NULL")
    elif parsed["lifecycle"] == "archived":
        clauses.append("c.ended_at IS NULL AND NOT s.consent")
    if tag_filter:
        clauses.append("EXISTS (SELECT 1 FROM session_tags st WHERE st.session_id=s.id AND st.tag=:tag)")
        bind["tag"] = tag_filter
    raw = db.execute(
        f"""SELECT s.id, s.candidate, s.role, s.consent, s.created_at, c.role_id, c.ended_at
            FROM active_sessions s LEFT JOIN session_context c ON c.session_id=s.id
            WHERE {' AND '.join(clauses)} ORDER BY s.created_at DESC, s.id ASC""",
        bind,
    ).fetchall()
    since_dt, until_dt = parsed["since"], parsed["until"]
    matched = []
    for row in raw:
        dt = _parse_utc(row["created_at"])
        if (since_dt is None or dt >= since_dt) and (until_dt is None or dt <= until_dt):
            matched.append((row, dt))
    return matched


def _compute_cohort(db: sqlite3.Connection, parsed: dict[str, Any], *, candidate_limit: int | None) -> dict[str, Any]:
    matched = _query_matching_sessions(db, parsed)
    sids = [row["id"] for row, _ in matched]
    tags_by_sid = _load_session_tags(db, sids)
    scores_by_sid = _load_scorecard_pcts(db, sids)
    counts_by_sid = _load_answer_counts(db, sids)

    lc_counts = {"active": 0, "finished": 0, "archived": 0}
    total_answers = total_explained = total_concerns = 0
    buckets = {key: 0 for key, *_ in _SCORE_BUCKETS}
    scored: list[float] = []
    timeline_map: dict[str, dict[str, int]] = defaultdict(lambda: {"sessions": 0, "finished": 0, "explained": 0, "concerns": 0})
    tag_stats: dict[str, dict[str, Any]] = defaultdict(lambda: {"session_count": 0, "explained": 0, "reviewed": 0, "scores": []})
    candidates_all: list[dict[str, Any]] = []

    for row, created_dt in matched:
        sid = row["id"]
        lc = "finished" if row["ended_at"] else ("active" if row["consent"] else "archived")
        lc_counts[lc] += 1
        ac = counts_by_sid[sid]
        explained, concerns = ac["explained_count"], ac["concern_count"]
        reviewed = explained + concerns
        total_answers += ac["answer_count"]
        total_explained += explained
        total_concerns += concerns
        score_pct = scores_by_sid.get(sid)
        if score_pct is not None:
            scored.append(score_pct)
            buckets[_bucket_key(score_pct)] += 1
        tl = timeline_map[created_dt.date().isoformat()]
        tl["sessions"] += 1
        tl["finished"] += int(lc == "finished")
        tl["explained"] += explained
        tl["concerns"] += concerns
        tags = tags_by_sid.get(sid, [])
        for t in tags:
            ts = tag_stats[t]
            ts["session_count"] += 1
            ts["explained"] += explained
            ts["reviewed"] += reviewed
            if score_pct is not None:
                ts["scores"].append(score_pct)
        candidates_all.append({
            "session_id": sid, "candidate": row["candidate"], "role": row["role"], "role_id": row["role_id"],
            "lifecycle": lc, "created_at": row["created_at"], "ended_at": row["ended_at"], "tags": tags,
            **ac, "weighted_score_pct": score_pct,
        })

    reviewed_total = total_explained + total_concerns
    return {
        "summary": {
            "session_count": len(matched), "active_count": lc_counts["active"],
            "finished_count": lc_counts["finished"], "archived_count": lc_counts["archived"],
            "answer_count": total_answers, "reviewed_count": reviewed_total,
            "pass_rate_pct": _pct(total_explained, reviewed_total),
            "concern_rate_pct": _pct(total_concerns, reviewed_total),
            "avg_scorecard_pct": round(sum(scored) / len(scored), 1) if scored else None,
            "scored_session_count": len(scored),
        },
        "score_buckets": [{"range": k, "label": lbl, "count": buckets[k]} for k, lbl, *_ in _SCORE_BUCKETS],
        "timeline": [{"date": day, **timeline_map[day]} for day in sorted(timeline_map)[-30:]],
        "tag_breakdown": [
            {
                "tag": t, "session_count": item["session_count"],
                "pass_rate_pct": _pct(item["explained"], item["reviewed"]),
                "avg_scorecard_pct": round(sum(item["scores"]) / len(item["scores"]), 1) if item["scores"] else None,
            }
            for t, item in sorted(tag_stats.items(), key=lambda e: (-e[1]["session_count"], e[0].casefold(), e[0]))[:20]
        ],
        "candidates": candidates_all[:candidate_limit] if candidate_limit is not None else candidates_all,
    }


@router.get("/analytics/cohorts")
def cohort_analytics(
    role_id: UUID | None = None, tag: str = Query(default="", max_length=32),
    lifecycle: LifecycleFilter = "", since: datetime | None = None, until: datetime | None = None,
):
    parsed = _validate_filters(role_id, tag, lifecycle, since, until)
    with store.connection() as db:
        return _compute_cohort(db, parsed, candidate_limit=200)


@router.get("/analytics/cohorts/export")
def export_cohort_analytics(
    role_id: UUID | None = None, tag: str = Query(default="", max_length=32),
    lifecycle: LifecycleFilter = "", since: datetime | None = None, until: datetime | None = None,
    format: ExportFormat = "csv",
):
    parsed = _validate_filters(role_id, tag, lifecycle, since, until)
    with store.connection() as db:
        data = _compute_cohort(db, parsed, candidate_limit=None if format == "csv" else 200)
    if format == "json":
        payload = {
            "format": "interviewcheck.cohort_analytics", "exported_at": store.timestamp(),
            "filters": {
                "role_id": parsed["role_id"], "tag": parsed["tag"], "lifecycle": parsed["lifecycle"],
                "since": parsed["since"].isoformat() if parsed["since"] else None,
                "until": parsed["until"].isoformat() if parsed["until"] else None,
            },
            **data,
        }
        return Response(
            json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8"), media_type="application/json",
            headers={"Content-Disposition": 'attachment; filename="cohort-analytics.json"', "Cache-Control": "no-store"},
        )
    output = SpooledTemporaryFile(max_size=1024 * 1024)
    try:
        output.write(("\ufeff" + exports.csv_row(CSV_HEADER)).encode("utf-8"))
        for r in data["candidates"]:
            output.write(exports.csv_row([
                r["session_id"], r["candidate"], r["role"], r["role_id"] or "", r["lifecycle"], r["created_at"],
                r["ended_at"] or "", "; ".join(r["tags"]), r["answer_count"], r["match_count"], r["explained_count"],
                r["concern_count"], r["pending_count"], "" if r["weighted_score_pct"] is None else r["weighted_score_pct"],
            ]).encode("utf-8"))
        output.seek(0)
        return StreamingResponse(
            iter(lambda: output.read(65536), b""), media_type="text/csv; charset=utf-8", background=BackgroundTask(output.close),
            headers={"Content-Disposition": 'attachment; filename="cohort-analytics.csv"', "Cache-Control": "no-store"},
        )
    except BaseException:
        output.close()
        raise
