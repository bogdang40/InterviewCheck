"""Selection-ordered interview identities and bounded count matrices for comparison reports."""
from html import escape

from . import report


MEASURES = (
    ("Captured answers", "answer_count"),
    ("Answers with a passage match", "match"),
    ("Answers without a passage match", "no_match"),
    ("Answers with limited evidence", "insufficient"),
    ("Pending dispositions", "pending"),
    ("Explained dispositions", "explained"),
    ("Unresolved dispositions", "unresolved"),
    ("Disclosed dispositions", "disclosed"),
)


def interview_title(number, session):
    name = session["candidate"]
    return f"Interview {number} · {name if name and name.strip() else 'Unnamed candidate'}"


def _matrices(sessions):
    for start in range(0, len(sessions), 3):
        group = sessions[start:start + 3]
        numbers = range(start + 1, start + len(group) + 1)
        caption = f"Interview {numbers[0]}" if len(group) == 1 else f"Interviews {numbers[0]} to {numbers[-1]}"
        rows = [(label, [s["answer_count"] if key == "answer_count" else s["counts"][key] for s in group])
                for label, key in MEASURES]
        yield caption, numbers, rows


def _policy(session):
    value = session["policy"]
    return value if value and value.strip() else "No policy recorded."


def markdown(sessions):
    lines = ["## Candidates", ""]
    for number, session in enumerate(sessions, 1):
        lines.extend([
            f"### {report.heading(interview_title(number, session))}", "", f"Interview ID {session['id']}", "",
            "Role", "", report.literal(session["role"] or "No role recorded."), "",
            f"Lifecycle · {session['lifecycle']}", "", "Assistance policy", "", report.literal(_policy(session)), "",
        ])
    lines.extend(["## Answer and review counts", ""])
    for caption, numbers, rows in _matrices(sessions):
        headers = [f"Interview {n}" for n in numbers]
        lines.extend([f"### {caption}", "", "| Measure | " + " | ".join(headers) + " |",
                      "| --- | " + " | ".join(["---:"] * len(headers)) + " |"])
        for label, values in rows:
            lines.append(f"| {label} | " + " | ".join(str(n) for n in values) + " |")
        lines.append("")
    return lines


def html(sessions):
    parts = ['<section class="candidate-identities"><h2>Candidates</h2>']
    for number, session in enumerate(sessions, 1):
        parts.append(
            f"<article><h3>{escape(interview_title(number, session))}</h3><dl>"
            f"<dt>Role</dt><dd>{escape(session['role'] or 'No role recorded.')}</dd>"
            f"<dt>Lifecycle</dt><dd>{escape(session['lifecycle'])}</dd>"
            f"<dt>Created</dt><dd>{escape(session['created_at'])}</dd>"
            f"<dt>Assistance policy</dt><dd>{escape(_policy(session))}</dd></dl></article>"
        )
    parts.append('</section><section class="comparison-counts"><h2>Answer and review counts</h2>')
    for caption, numbers, rows in _matrices(sessions):
        parts.append(f'<table><caption>{caption}</caption><thead><tr><th scope="col">Measure</th>')
        parts.extend(f'<th scope="col" aria-label="Interview {n}"><span class="interview-prefix">Interview </span>{n}</th>'
                     for n in numbers)
        parts.append("</tr></thead><tbody>")
        for label, values in rows:
            parts.append(f'<tr><th scope="row">{label}</th>' + "".join(f"<td>{n}</td>" for n in values) + "</tr>")
        parts.append("</tbody></table>")
    parts.append("</section>")
    return "".join(parts)
