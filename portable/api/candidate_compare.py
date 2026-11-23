"""Cross-candidate comparison matrix and printable/Markdown comparison dossier."""
from html import escape
import json
from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import HTMLResponse, Response
from pydantic import Field, model_validator

from . import exports, report, store
from .models import Input, RequestID

router = APIRouter()
EXCERPT_CHARS = 240
_ZERO_COUNTS = ("match", "no_match", "insufficient", "pending", "explained", "unresolved", "disclosed")


class CompareInput(Input):
    session_ids: list[RequestID] = Field(min_length=2, max_length=6)
    include_excerpts: bool = False
    include_notes: bool = False

    @model_validator(mode="after")
    def require_unique_sessions(self):
        if len(set(self.session_ids)) != len(self.session_ids):
            raise ValueError("Select each interview only once.")
        return self


class CompareDossierInput(CompareInput):
    format: Literal["markdown", "html"]


def _cap_excerpt(text: str) -> str:
    stripped = text.strip()
    return stripped if len(stripped) <= EXCERPT_CHARS else stripped[: EXCERPT_CHARS - 1] + "…"


def _parse_print_ids(ids: str) -> list[UUID]:
    parts = [part.strip() for part in ids.split(",")]
    if any(not part for part in parts) or not 2 <= len(parts) <= 6:
        raise HTTPException(422, "Provide between 2 and 6 unique interview IDs.")
    parsed: list[UUID] = []
    seen: set[UUID] = set()
    for part in parts:
        try:
            uid = UUID(part)
        except ValueError as exc:
            raise HTTPException(422, "Invalid interview ID in comparison query.") from exc
        if uid in seen:
            raise HTTPException(422, "Select each interview only once.")
        seen.add(uid)
        parsed.append(uid)
    return parsed


def _load_shared_rubric(db, sessions_out: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not any(col[1] == "rubric_json" for col in db.execute("PRAGMA table_info(roles)")):
        return []
    role_ids = {item["role_id"] for item in sessions_out}
    shared_role_id = next(iter(role_ids)) if len(role_ids) == 1 else None
    if shared_role_id is None:
        return []
    row = db.execute("SELECT rubric_json FROM roles WHERE id=?", (shared_role_id,)).fetchone()
    try:
        raw = json.loads(row["rubric_json"]) if row and row["rubric_json"] else []
    except ValueError:
        return []
    if not isinstance(raw, list):
        return []
    criteria: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict) or not item.get("criterion"):
            continue
        try:
            weight = int(item.get("weight", 1))
        except (TypeError, ValueError):
            weight = 1
        signals, flags = item.get("expected_signals") or [], item.get("red_flags") or []
        criteria.append({
            "criterion": str(item["criterion"]), "weight": weight,
            "expected_signals": [str(x) for x in signals] if isinstance(signals, list) else [],
            "red_flags": [str(x) for x in flags] if isinstance(flags, list) else [],
        })
    return criteria


def _comparison_slots(plans, planned_answers, unplanned_answers):
    def owned_row(slot, sid, answer):
        return {
            "slot": slot, "owner_session_id": sid, "planned_question": None,
            "cells": {key: answer if key == sid else None for key in plans},
        }

    rows = []
    last_slot = max(max(map(len, plans.values())), max(planned_answers, default=0))
    for number in range(1, last_slot + 1):
        prompts = {sid: questions[number - 1] if number <= len(questions) else None for sid, questions in plans.items()}
        distinct = set(prompts.values())
        shared = distinct.pop() if len(distinct) == 1 else None
        cells = dict.fromkeys(plans)
        row = {"slot": number, "planned_question": shared, "cells": cells}
        if shared is None:
            row["planned_questions"] = prompts
        rows.append(row)
        # Answers arrive in recording order, independent of the requested candidate order.
        for sid, answer in planned_answers.get(number, []):
            if cells[sid] is None:
                cells[sid] = answer
            else:
                extra = owned_row(number, sid, answer)
                extra["planned_questions"] = {sid: prompts[sid]}
                rows.append(extra)
    rows.extend(owned_row("unslotted", sid, answer) for sid, answer in unplanned_answers)
    return rows


def _load_comparison(session_ids: list[UUID], *, include_excerpts: bool, include_notes: bool) -> dict[str, Any]:
    ordered_ids = [str(uid) for uid in session_ids]
    placeholders = ",".join("?" for _ in ordered_ids)
    with store.connection() as db:
        session_rows = db.execute(
            f"SELECT s.id, s.candidate, s.role, s.policy, s.consent, s.created_at, c.role_id, c.questions, c.ended_at "
            f"FROM active_sessions s LEFT JOIN session_context c ON c.session_id = s.id WHERE s.id IN ({placeholders})",
            ordered_ids,
        ).fetchall()
        by_id = {row["id"]: row for row in session_rows}
        if len(by_id) != len(ordered_ids):
            raise HTTPException(404, "One or more interviews do not exist.")
        private_columns = (", answer" if include_excerpts else "") + (", note" if include_notes else "")
        answer_rows = db.execute(
            f"SELECT id, session_id, question, result, status, disposition, planned_slot{private_columns} "
            f"FROM answers WHERE session_id IN ({placeholders}) ORDER BY rowid",
            ordered_ids,
        ).fetchall()

        counts_by_sid = {sid: {k: 0 for k in _ZERO_COUNTS} for sid in ordered_ids}
        planned_answers = {}
        unplanned_answers = []

        for arow in answer_rows:
            sid, counts = arow["session_id"], counts_by_sid[arow["session_id"]]
            status, disposition = arow["status"], arow["disposition"]
            if status in counts:
                counts[status] += 1
            if disposition in counts:
                counts[disposition] += 1
            result_data = json.loads(arow["result"]) if arow["result"] else {}
            cell: dict[str, Any] = {
                "answer_id": arow["id"], "question": arow["question"], "status": status,
                "disposition": disposition, "passage_count": len(result_data.get("passages", [])),
            }
            if include_excerpts:
                cell["excerpt"] = _cap_excerpt(arow["answer"] or "")
            if include_notes:
                cell["note"] = arow["note"] or ""
            slot = arow["planned_slot"]
            if isinstance(slot, int) and slot >= 1:
                planned_answers.setdefault(slot, []).append((sid, cell))
            else:
                unplanned_answers.append((sid, cell))

        planned_lists: dict[str, list[str]] = {}
        sessions_out: list[dict[str, Any]] = []
        for sid in ordered_ids:
            srow = by_id[sid]
            questions = json.loads(srow["questions"]) if srow["questions"] else []
            planned_lists[sid] = questions
            counts = counts_by_sid[sid]
            lifecycle = "finished" if srow["ended_at"] else ("active" if srow["consent"] else "archived")
            sessions_out.append({
                "id": sid, "candidate": srow["candidate"], "role": srow["role"], "role_id": srow["role_id"],
                "lifecycle": lifecycle, "created_at": srow["created_at"], "ended_at": srow["ended_at"],
                "consent": bool(srow["consent"]), "policy": srow["policy"],
                "answer_count": counts["match"] + counts["no_match"] + counts["insufficient"], "counts": counts,
            })

        slots_out = _comparison_slots(planned_lists, planned_answers, unplanned_answers)
        rubric_criteria = _load_shared_rubric(db, sessions_out)
    return {"sessions": sessions_out, "slots": slots_out, "rubric_criteria": rubric_criteria}


def _slot_title(slot):
    if slot["slot"] == "unslotted":
        return "Unslotted exchange"
    title = f"Slot {slot['slot']}"
    return title + " (additional answer)" if "owner_session_id" in slot else title


def _render_markdown(data: dict[str, Any]) -> str:
    sessions = data["sessions"]
    lines = [
        "# Candidate comparison dossier", "", "Shared wording requires interpretation against the interview rules.", "",
        "## Candidates", "",
        "| Candidate | Role | Lifecycle | Answers | Matches | Pending | Explained | Unresolved | Disclosed |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for s in sessions:
        c = s["counts"]
        lines.append(
            f"| {report.heading(s['candidate'])} | {report.heading(s['role'])} | {s['lifecycle']} | "
            f"{s['answer_count']} | {c['match']} | {c['pending']} | {c['explained']} | {c['unresolved']} | {c['disclosed']} |"
        )
    lines.extend(["", "### Session policies", ""])
    for s in sessions:
        lines.extend([f"**{report.heading(s['candidate'])}** ({s['id']})", "", report.literal(s["policy"]), ""])
    if data["rubric_criteria"]:
        lines.extend(["## Shared role rubric", ""])
        for crit in data["rubric_criteria"]:
            lines.extend([f"### {report.heading(crit['criterion'])} (weight {crit['weight']})", ""])
            if crit["expected_signals"]:
                lines.extend(["Expected signals", "", report.literal("\n".join(crit["expected_signals"])), ""])
            if crit["red_flags"]:
                lines.extend(["Red flags", "", report.literal("\n".join(crit["red_flags"])), ""])
    lines.extend(["## Question slot comparison", ""])
    for slot in data["slots"]:
        lines.extend([f"### {_slot_title(slot)}", ""])
        if slot["planned_question"]:
            lines.extend(["Planned question", "", report.literal(slot["planned_question"]), ""])
        for s in sessions:
            if "owner_session_id" in slot and slot["owner_session_id"] != s["id"]:
                continue
            cell = slot["cells"][s["id"]]
            lines.extend([f"**{report.heading(s['candidate'])}**", ""])
            prompts = slot.get("planned_questions")
            if prompts is not None:
                prompt = prompts[s["id"]]
                if prompt is None:
                    lines.extend(["Not in this interview plan.", ""])
                    if cell is None:
                        continue
                else:
                    lines.extend(["Planned question", "", report.literal(prompt), ""])
            if cell is None:
                lines.extend(["No recorded answer", ""])
                continue
            lines.extend([
                f"status={cell['status']}, disposition={cell['disposition']}, passages={cell['passage_count']}", "",
            ])
            if prompts is None or prompts[s["id"]] != cell["question"]:
                lines.extend(["Recorded question", "", report.literal(cell["question"]), ""])
            if "excerpt" in cell:
                lines.extend(["Answer excerpt", "", report.literal(cell["excerpt"]), ""])
            if cell.get("note"):
                lines.extend(["Interviewer note", "", report.literal(cell["note"]), ""])
    return "\n".join(lines).rstrip() + "\n"


def _render_html(data: dict[str, Any]) -> str:
    sessions = data["sessions"]
    summary_rows = "".join(
        f"<tr><td>{escape(s['candidate'])}</td><td>{escape(s['role'])}</td><td>{escape(s['lifecycle'])}</td>"
        f"<td>{escape(s['created_at'])}</td><td>{escape(s['policy'])}</td><td>{s['answer_count']}</td>"
        f"<td>{s['counts']['match']}</td><td>{s['counts']['no_match']}</td><td>{s['counts']['insufficient']}</td>"
        f"<td>{s['counts']['pending']}</td><td>{s['counts']['explained']}</td>"
        f"<td>{s['counts']['unresolved']}</td><td>{s['counts']['disclosed']}</td></tr>" for s in sessions
    )
    rubric_html = ""
    if data["rubric_criteria"]:
        items = "".join(
            f"<article><h3>{escape(c['criterion'])} (weight {c['weight']})</h3>"
            f"<p>Expected signals: {escape(', '.join(c['expected_signals']) or 'None')}</p>"
            f"<p>Red flags: {escape(', '.join(c['red_flags']) or 'None')}</p></article>" for c in data["rubric_criteria"]
        )
        rubric_html = f"<section><h2>Shared role rubric</h2>{items}</section>"
    slot_articles = []
    for slot in data["slots"]:
        heading = _slot_title(slot)
        planned = f"<p>Planned question: {escape(slot['planned_question'])}</p>" if slot["planned_question"] else ""
        cells = []
        for s in sessions:
            if "owner_session_id" in slot and slot["owner_session_id"] != s["id"]:
                continue
            cell = slot["cells"][s["id"]]
            prompt_html = ""
            prompts = slot.get("planned_questions")
            if prompts is not None:
                prompt = prompts[s["id"]]
                prompt_html = (f"<p>Planned question: {escape(prompt)}</p>" if prompt is not None
                               else "<p>Not in this interview plan.</p>")
            if cell is None:
                empty = "" if prompts is not None and prompts[s["id"]] is None else "<p>No recorded answer.</p>"
                cells.append(f"<div><h3>{escape(s['candidate'])}</h3>{prompt_html}{empty}</div>")
                continue
            question_html = ""
            if prompts is None or prompts[s["id"]] != cell["question"]:
                question_html = f"<p>Recorded question: {escape(cell['question'])}</p>"
            extra = (f"<p>Excerpt: {escape(cell['excerpt'])}</p>" if "excerpt" in cell else "") + (
                f"<p>Note: {escape(cell['note'])}</p>" if cell.get("note") else ""
            )
            cells.append(
                f"<div><h3>{escape(s['candidate'])}</h3>{prompt_html}{question_html}"
                f"<p>Status: {escape(cell['status'])}, Disposition: {escape(cell['disposition'])}, Passages: {cell['passage_count']}</p>{extra}</div>"
            )
        slot_articles.append(f"<article><h2>{escape(heading)}</h2>{planned}{''.join(cells)}</article>")
    return (
        f"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        f"<title>Candidate comparison dossier</title><style>{exports.STYLE}</style><script src=\"/api/exports/print.js\" defer></script></head><body>"
        f"<nav aria-label=\"Report actions\"><button type=\"button\" id=\"print-report\">Print or save PDF</button></nav>"
        f"<main><h1>Candidate comparison dossier</h1><p>Shared wording requires interpretation against the interview rules.</p>"
        f"<table><thead><tr><th>Candidate</th><th>Role</th><th>Lifecycle</th><th>Created</th><th>Policy</th>"
        f"<th>Answers</th><th>Match</th><th>No match</th><th>Insufficient</th><th>Pending</th><th>Explained</th><th>Unresolved</th><th>Disclosed</th>"
        f"</tr></thead><tbody>{summary_rows}</tbody></table>{rubric_html}"
        f"<section><h2>Question slot comparison</h2>{''.join(slot_articles) or '<p>No slots recorded.</p>'}</section></main></body></html>"
    )


@router.post("/interviews/compare")
def compare_candidates(item: CompareInput):
    return _load_comparison(item.session_ids, include_excerpts=item.include_excerpts, include_notes=item.include_notes)


@router.post("/interviews/compare/dossier")
def compare_dossier(item: CompareDossierInput):
    data = _load_comparison(item.session_ids, include_excerpts=item.include_excerpts, include_notes=item.include_notes)
    if item.format == "markdown":
        return Response(_render_markdown(data), media_type="text/markdown; charset=utf-8",
                        headers={"Content-Disposition": 'attachment; filename="candidate-comparison.md"', "Cache-Control": "no-store"})
    return HTMLResponse(_render_html(data), headers={"Cache-Control": "no-store"})


@router.get("/interviews/compare/print", response_class=HTMLResponse)
def compare_print(ids: str = Query(..., min_length=36, max_length=300), include_excerpts: bool = False, include_notes: bool = False):
    data = _load_comparison(_parse_print_ids(ids), include_excerpts=include_excerpts, include_notes=include_notes)
    return HTMLResponse(_render_html(data), headers={"Cache-Control": "no-store"})
