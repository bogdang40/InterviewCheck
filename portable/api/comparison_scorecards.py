"""Read and render the saved ratings for each interview selected for comparison."""
from html import escape

from fastapi import HTTPException

from . import report
from .scorecard_math import weighted_score_pct


def add_saved_scorecards(db, sessions, *, include_rationales):
    items_by_session = {session["id"]: [] for session in sessions}
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_scorecards'").fetchone():
        placeholders = ",".join("?" for _ in sessions)
        rationale = ", rationale" if include_rationales else ""
        rows = db.execute(
            f"SELECT session_id, criterion_id, criterion_label, weight, rating{rationale} "
            f"FROM session_scorecards WHERE session_id IN ({placeholders}) ORDER BY rowid",
            tuple(items_by_session),
        )
        for row in rows:
            item = dict(row)
            sid = item.pop("session_id")
            if (type(item["weight"]) is not int or not 1 <= item["weight"] <= 100
                    or type(item["rating"]) is not int or not 1 <= item["rating"] <= 5
                    or not all(isinstance(item[k], str) for k in ("criterion_label", "criterion_id"))
                    or (include_rationales and not isinstance(item["rationale"], str))):
                raise HTTPException(409, "A saved criterion has invalid scorecard data.")
            items_by_session[sid].append(item)
    for session in sessions:
        items = items_by_session[session["id"]]
        session["scorecard"] = {"rated_count": len(items), "weighted_score_pct": weighted_score_pct(items), "items": items}


def _summary(scorecard):
    count = scorecard["rated_count"]
    if count == 0:
        return "No saved ratings."
    noun = "rating" if count == 1 else "ratings"
    return f"{count} saved {noun}. Weighted score {scorecard['weighted_score_pct']:.1f}%."


def markdown(sessions):
    if "scorecard" not in sessions[0]:
        return []
    lines = ["## Saved interview scorecards", "", "Each percentage uses the weights of that interview’s saved ratings.", ""]
    for session in sessions:
        card = session["scorecard"]
        lines.extend([f"### {report.heading(session['candidate'])}", "", f"Interview {session['id']}", "", _summary(card), ""])
        for item in card["items"]:
            lines.extend([f"#### {report.heading(item['criterion_label'])}", "",
                          f"Criterion ID {report.heading(item['criterion_id'])}", "",
                          f"Rating {item['rating']}/5 · Weight {item['weight']}", ""])
            if "rationale" in item:
                lines.extend(["Rationale", "", report.literal(item["rationale"]) if item["rationale"] else "None recorded.", ""])
    return lines


def html(sessions):
    if "scorecard" not in sessions[0]:
        return ""
    parts = ["<section><h2>Saved interview scorecards</h2><p>Each percentage uses the weights of that interview’s saved ratings.</p>"]
    for session in sessions:
        card = session["scorecard"]
        parts.append(f"<article><h3>{escape(session['candidate'])}</h3><p>Interview {escape(session['id'])}</p><p>{_summary(card)}</p>")
        for item in card["items"]:
            parts.append(f"<h4>{escape(item['criterion_label'])}</h4><p>Criterion ID {escape(item['criterion_id'])}</p>"
                         f"<p>Rating {item['rating']}/5 · Weight {item['weight']}</p>")
            if "rationale" in item:
                parts.append(f"<p>Rationale</p><pre>{escape(item['rationale']) if item['rationale'] else 'None recorded.'}</pre>")
        parts.append("</article>")
    return "".join(parts) + "</section>"
