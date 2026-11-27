"""Archive CSV and a printable report for a single interview."""
import base64
import csv
import hashlib
from html import escape
from io import StringIO
import json
from uuid import UUID
from tempfile import SpooledTemporaryFile

from starlette.background import BackgroundTask

from fastapi import APIRouter
from fastapi.responses import HTMLResponse, Response, StreamingResponse

from . import review_brief, store
from .lineage import description as origin_description
from .scorecard_math import weighted_score_pct

router = APIRouter()
router.include_router(review_brief.router)


def csv_cell(value):
    text = "" if value is None else str(value)
    if text.startswith(("\t", "\r", "\n")) or text.lstrip().startswith(("=", "+", "-", "@")):
        return "'" + text
    return text


def csv_row(values):
    output = StringIO(newline="")
    csv.writer(output).writerow([csv_cell(value) for value in values])
    return output.getvalue()


def archive_rows():
    yield "\ufeff" + csv_row(["Session ID", "Date", "Candidate", "Role", "Resource policy", "Notice recorded",
                             "Question", "Answer", "Comparison", "Source", "First matched excerpt",
                             "Interviewer disposition", "Interviewer note", "Native score", "Native verdict", "Permitted source snapshot",
                             "Exchange ID", "Parent exchange ID", "Planned slot", "Planned question"])
    with store.connection() as db:
        # A left join retains interviews for which no answer was captured.
        cursor = db.execute("""SELECT s.id,s.created_at,s.candidate,s.role,s.policy,s.consent,
            a.question,a.answer,a.status,a.result,a.disposition,a.note,a.legacy,c.permitted_sources,
            a.id exchange_id,a.parent_answer_id,a.planned_slot,
            CASE WHEN a.planned_slot>0 THEN json_extract(c.questions,'$['||(a.planned_slot-1)||']') END planned_question
            FROM active_sessions s LEFT JOIN answers a ON a.session_id=s.id LEFT JOIN session_context c ON c.session_id=s.id
            ORDER BY s.created_at DESC,s.id,a.rowid""")
        for row in cursor:
            result = json.loads(row["result"]) if row["result"] else {}
            passage = next(iter(result.get("passages", [])), {})
            legacy = json.loads(row["legacy"]) if row["legacy"] else {}
            yield csv_row([row["id"], row["created_at"], row["candidate"], row["role"], row["policy"],
                           "Yes" if row["consent"] else "Unknown", row["question"], row["answer"], row["status"],
                           passage.get("label"), passage.get("answer_excerpt"), row["disposition"], row["note"],
                           (legacy.get("score") or {}).get("percent"), (legacy.get("label") or {}).get("label"), row["permitted_sources"] or "[]",
                           row["exchange_id"], row["parent_answer_id"], row["planned_slot"], row["planned_question"]])


@router.get("/exports/interviews.csv")
def archive_csv():
    return csv_download(archive_rows(), "interviews.csv")


def csv_download(rows, filename: str):
    # Finish the SQLite snapshot on this thread. HTTP streaming can resume on
    # another worker, and a slow download must release the SQLite read lock.
    output = SpooledTemporaryFile(max_size=1024 * 1024)
    try:
        for row in rows:
            output.write(row.encode("utf-8"))
        output.seek(0)
        return StreamingResponse(iter(lambda: output.read(65536), b""), media_type="text/csv; charset=utf-8",
                                 background=BackgroundTask(output.close),
                                 headers={"Content-Disposition": f'attachment; filename="{filename}"', "Cache-Control": "no-store"})
    except BaseException:
        output.close()
        raise


STYLE = """
body {font: 16px/1.5 system-ui,sans-serif; color:#182b20; max-width:52rem; margin:2rem auto; padding:0 1.25rem;}
h1,h2,h3 {line-height:1.22; break-after:avoid; overflow-wrap:anywhere;} h1 {font-size:2rem;} h2 {margin-top:2rem;}
h3 {font-size:1.02rem;} dt {font-weight:650;} dd {margin:0 0 .7rem;}
p,blockquote,pre,dd {white-space:pre-wrap;overflow-wrap:anywhere;}
blockquote {border-left:3px solid #839e8c;padding-left:1rem;margin:.5rem 0 1rem;}
article {border-top:1px solid #a8b4a8;margin-top:1.8rem;} pre {font-size:.78rem;}
button {background:#194a33;color:white;border:0;border-radius:5px;padding:.7rem 1rem;font-size:1rem;cursor:pointer;}
.comparison-report {overflow-wrap:anywhere;}
.comparison-report h4 {break-after:avoid;line-height:1.3;}
.comparison-report pre {font:inherit;white-space:pre-wrap;}
.comparison-report .candidate-identities article {margin-top:.9rem;}
.comparison-report .candidate-identities dl {margin:.35em 0;}
.comparison-report .comparison-counts table {width:100%;table-layout:fixed;border-collapse:collapse;margin:1em 0 1.4em;}
.comparison-report caption {text-align:left;font-weight:650;margin-bottom:.35em;break-after:avoid;}
.comparison-report th,.comparison-report td {padding:.3em .4em;border-bottom:1px solid #a8b4a8;vertical-align:top;line-height:1.35;}
.comparison-report th:first-child {width:40%;text-align:left;}
.comparison-report th:not(:first-child),.comparison-report td {text-align:right;font-variant-numeric:tabular-nums;}
@media screen and (max-width:28rem) {
  .comparison-report thead th {font-size:.875em;}
  .comparison-report .interview-prefix {display:none;}
  .comparison-report th,.comparison-report td {padding:.3em .15em;}
  .comparison-report th:first-child {width:35%;}
}
@media print {
  .comparison-report thead {display:table-header-group;}
  .comparison-report tr {break-inside:avoid;}
  .comparison-report dt {break-after:avoid;}
}
@media print {body{margin:0;max-width:none;padding:0;font-size:10.5pt;} nav{display:none;} @page{margin:17mm;}}
"""
PRINT_STYLE_HASH = "sha256-" + base64.b64encode(hashlib.sha256(STYLE.encode("utf-8")).digest()).decode("ascii")
PRINT_JS = """(() => {
  const bind = () => {
    const button = document.getElementById("print-report");
    if (button) button.addEventListener("click", () => window.print());
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", bind);
  else bind();
})();
"""


@router.get("/exports/print.js")
def print_script():
    return Response(PRINT_JS, media_type="application/javascript; charset=utf-8")


def text_block(title, value):
    return f"<h3>{escape(title)}</h3><p>{escape(str(value))}</p>"


def _has_table(db, name: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def render_scorecard(db, sid: str) -> str:
    if not _has_table(db, "session_scorecards"):
        return ""
    rows = db.execute("SELECT criterion_label,weight,rating,rationale FROM session_scorecards WHERE session_id=? ORDER BY rowid", (sid,)).fetchall()
    pct = weighted_score_pct(rows)
    if pct is None:
        return ""
    items = "".join(
        f"<dt>{escape(r['criterion_label'])} (weight {int(r['weight'])})</dt>"
        f"<dd>Rating: {int(r['rating'])}/5" + (f" - {escape(r['rationale'])}" if r["rationale"] else "") + "</dd>"
        for r in rows
    )
    return f"<section><h2>Rubric scorecard</h2><p>Weighted score: {pct:.1f}%</p><dl>{items}</dl></section>"


def render_handoff_notes(db, sid: str) -> str:
    if not _has_table(db, "session_handoff_notes"):
        return ""
    rows = db.execute(
        "SELECT author_email,category,body,created_at FROM session_handoff_notes WHERE session_id=? ORDER BY created_at DESC, id DESC",
        (sid,),
    ).fetchall()
    if not rows:
        return "<section><h2>Panel handoff notes</h2><p>No handoff notes recorded.</p></section>"
    items = "".join(f"<dt>{escape(r['category'])} by {escape(r['author_email'])} ({escape(r['created_at'])})</dt><dd>{escape(r['body'])}</dd>" for r in rows)
    return f"<section><h2>Panel handoff notes</h2><dl>{items}</dl></section>"


def print_answer(index, record, origin, *, include_sources=True, include_legacy=True, redact_candidate=False):
    finding = record["result"]
    blocks = [f"<article><h2>Question {index}</h2><p>{escape(record['question'])}</p>"]
    if not redact_candidate:
        blocks.append(text_block("Captured answer", record["answer"]))
    blocks.append(text_block("Comparison", finding["explanation"]))
    if origin:
        blocks.append(text_block("Question origin", origin))
    if redact_candidate:
        blocks.append(text_block("Matched passages", len(finding["passages"])))
    for item in finding["passages"]:
        blocks.extend([text_block("Source", item["label"]), text_block("Total matching words", item["words"])])
        if not redact_candidate:
            blocks.append(text_block("Candidate excerpt", item["answer_excerpt"]))
            if include_sources:
                blocks.append(text_block("Source excerpt", item["source_excerpt"]))
    if include_sources:
        for ref in record["references"]:
            blocks.append(text_block(("Permitted source: " if ref["permitted"] else "Comparison source: ") + ref["label"], ref["text"]))
    if not redact_candidate:
        blocks.append(text_block("Follow up", finding["follow_up"]))
    blocks.extend([text_block("Review outcome", record["disposition"]), text_block("Interviewer note", record["note"] or "No note recorded.")])
    if include_legacy and not redact_candidate and record.get("legacy"):
        blocks.append("<h3>Original native answer record</h3><pre>" + escape(json.dumps(record["legacy"], indent=2, ensure_ascii=False)) + "</pre>")
    return "".join(blocks) + "</article>"


@router.get("/sessions/{sid}/print", response_class=HTMLResponse)
def print_view(
    sid: UUID,
    include_sources: bool = True,
    include_scorecard: bool = True,
    include_handoff_notes: bool = False,
    include_legacy: bool = True,
    redact_candidate: bool = False,
):
    with store.connection() as db:
        session = store.get_session(db, str(sid))
        scorecard = render_scorecard(db, str(sid)) if include_scorecard else ""
        handoff_notes = render_handoff_notes(db, str(sid)) if include_handoff_notes else ""
    heading = "Interview review for " + ("Candidate [Redacted]" if redact_candidate else (session["candidate"] or "unnamed candidate"))
    meta = "".join(f"<dt>{label}</dt><dd>{escape(value)}</dd>" for label, value in [
        ("Role", session["role"]), ("Date", session["created_at"]), ("Finished", session["ended_at"] or "In progress"), ("Resource policy", session["policy"]),
        ("Candidate notice recorded", "Yes" if session["consent"] else "Unknown")])
    materials = "".join(text_block("Permitted source: " + s["label"], s["text"]) for s in session["permitted_sources"]) if include_sources else ""
    ordinals = {a["id"]: idx for idx, a in enumerate(session["answers"], 1)}
    answers = "".join(
        print_answer(i, a, origin_description(a, session["planned_questions"], ordinals),
                     include_sources=include_sources, include_legacy=include_legacy, redact_candidate=redact_candidate)
        for i, a in enumerate(session["answers"], 1)
    )
    legacy = session.get("legacy") if (include_legacy and not redact_candidate) else None
    metadata = ("<h2>Original native session record</h2><pre>" + escape(json.dumps(legacy, indent=2, ensure_ascii=False)) + "</pre>") if legacy else ""
    return HTMLResponse(f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{escape(heading)}</title>
<style>{STYLE}</style><script src="/api/exports/print.js" defer></script></head><body><nav aria-label="Report actions"><button type="button" id="print-report">Print or save PDF</button></nav>
<main><h1>{escape(heading)}</h1><dl>{meta}</dl>{materials}{scorecard}{handoff_notes}<p>Shared wording requires interpretation against the interview rules.</p>
{answers or "<p>No answers recorded.</p>"}{metadata}</main></body></html>""")
