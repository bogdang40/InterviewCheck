"""Archive CSV and a printable report for a single interview."""
from html import escape
import csv
from io import StringIO
import json
from uuid import UUID
from tempfile import SpooledTemporaryFile

from starlette.background import BackgroundTask

from fastapi import APIRouter
from fastapi.responses import HTMLResponse, StreamingResponse

from . import store

router = APIRouter()


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
                             "Interviewer disposition", "Interviewer note", "Native score", "Native verdict"])
    with store.connection() as db:
        # A left join retains interviews for which no answer was captured.
        cursor = db.execute("""SELECT s.id,s.created_at,s.candidate,s.role,s.policy,s.consent,
            a.question,a.answer,a.status,a.result,a.disposition,a.note,a.legacy
            FROM sessions s LEFT JOIN answers a ON a.session_id=s.id
            ORDER BY s.created_at DESC,s.id,a.rowid""")
        for row in cursor:
            result = json.loads(row["result"]) if row["result"] else {}
            passage = next(iter(result.get("passages", [])), {})
            legacy = json.loads(row["legacy"]) if row["legacy"] else {}
            yield csv_row([row["id"], row["created_at"], row["candidate"], row["role"], row["policy"],
                           "Yes" if row["consent"] else "Unknown", row["question"], row["answer"], row["status"],
                           passage.get("label"), passage.get("answer_excerpt"), row["disposition"], row["note"],
                           (legacy.get("score") or {}).get("percent"), (legacy.get("label") or {}).get("label")])


@router.get("/exports/interviews.csv")
def archive_csv():
    # Finish the SQLite snapshot on this thread. HTTP streaming can resume on
    # another worker, and a slow download must release the SQLite read lock.
    output = SpooledTemporaryFile(max_size=1024 * 1024)
    try:
        for row in archive_rows():
            output.write(row.encode("utf-8"))
        output.seek(0)
        return StreamingResponse(iter(lambda: output.read(65536), b""), media_type="text/csv; charset=utf-8",
                                 background=BackgroundTask(output.close),
                                 headers={"Content-Disposition": 'attachment; filename="interviews.csv"'})
    except BaseException:
        output.close()
        raise


STYLE = """
body {font: 16px/1.5 system-ui,sans-serif; color:#182b20; max-width:52rem; margin:2rem auto; padding:0 1.25rem;}
h1,h2,h3 {line-height:1.22; break-after:avoid;} h1 {font-size:2rem;} h2 {margin-top:2rem;}
h3 {font-size:1.02rem;} dt {font-weight:650;} dd {margin:0 0 .7rem;}
p,blockquote,pre,dd {white-space:pre-wrap;overflow-wrap:anywhere;}
blockquote {border-left:3px solid #839e8c;padding-left:1rem;margin:.5rem 0 1rem;}
article {border-top:1px solid #a8b4a8;margin-top:1.8rem;} pre {font-size:.78rem;}
button {background:#194a33;color:white;border:0;border-radius:5px;padding:.7rem 1rem;font-size:1rem;cursor:pointer;}
@media print {body{margin:0;max-width:none;padding:0;font-size:10.5pt;} nav{display:none;} @page{margin:17mm;}}
"""


def text_block(title, value):
    return f"<h3>{escape(title)}</h3><p>{escape(str(value))}</p>"


def print_answer(index, record):
    finding = record["result"]
    blocks = [f"<article><h2>Question {index}</h2><p>{escape(record['question'])}</p>",
              text_block("Captured answer", record["answer"]), text_block("Comparison", finding["explanation"])]
    for item in finding["passages"]:
        blocks.extend([text_block("Source", item["label"]), text_block("Total matching words", item["words"]),
                       text_block("Candidate excerpt", item["answer_excerpt"]), text_block("Source excerpt", item["source_excerpt"])])
    for ref in record["references"]:
        blocks.append(text_block(("Permitted source: " if ref["permitted"] else "Comparison source: ") + ref["label"], ref["text"]))
    blocks.extend([text_block("Follow up", finding["follow_up"]), text_block("Review outcome", record["disposition"]),
                   text_block("Interviewer note", record["note"] or "No note recorded.")])
    if record.get("legacy"):
        blocks.append("<h3>Original native answer record</h3><pre>" + escape(json.dumps(record["legacy"], indent=2, ensure_ascii=False)) + "</pre>")
    return "".join(blocks) + "</article>"


@router.get("/sessions/{sid}/print", response_class=HTMLResponse)
def print_view(sid: UUID):
    with store.connection() as db:
        session = store.get_session(db, str(sid))
    heading = "Interview review for " + (session["candidate"] or "unnamed candidate")
    meta = "".join(f"<dt>{label}</dt><dd>{escape(value)}</dd>" for label, value in [
        ("Role", session["role"]), ("Date", session["created_at"]), ("Finished", session["ended_at"] or "In progress"), ("Resource policy", session["policy"]),
        ("Candidate notice recorded", "Yes" if session["consent"] else "Unknown")])
    answers = "".join(print_answer(i, item) for i, item in enumerate(session["answers"], 1))
    legacy = session.get("legacy")
    metadata = ("<h2>Original native session record</h2><pre>" + escape(json.dumps(legacy, indent=2, ensure_ascii=False))
                + "</pre>") if legacy else ""
    return HTMLResponse(f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{escape(heading)}</title>
<style>{STYLE}</style></head><body><nav aria-label="Report actions"><button onclick="window.print()">Print or save PDF</button></nav>
<main><h1>{escape(heading)}</h1><dl>{meta}</dl><p>Shared wording requires interpretation against the interview rules.</p>
{answers or "<p>No answers recorded.</p>"}{metadata}</main></body></html>""")
