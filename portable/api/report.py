"""Format quoted evidence as literal Markdown blocks, preserving source text."""
import json
import re


def literal(text):
    # An indented code block prevents transcript text from creating HTML or links.
    return "\n".join("    " + line for line in str(text).splitlines()) or "    (empty)"


def heading(text):
    return re.sub(r"([\\\x60*_{}\[\]()#+.!<>|~-])", r"\\\1", " ".join(text.splitlines()))


def report(session):
    lines = ["# Interview review", "", "## Session", "", literal(
        f"{session['candidate']}\n{session['role']}\n{session['created_at']}"), "",
        f"Candidate notice recorded: {'Yes' if session['consent'] else 'Unknown'}", "",
        "### Agreed resources", "", literal(session["policy"]), "",
        "Shared wording requires interpretation against the interview rules.", ""]
    for i, record in enumerate(session["answers"], 1):
        finding = record["result"]
        lines += [f"## Question {i}", "", literal(record["question"]), "", "### Captured answer", "",
                  literal(record["answer"]), "", "### Comparison", "", finding["explanation"], ""]
        for passage in finding["passages"]:
            lines += [f"**{heading(passage['label'])}** ({passage['words']} words)", "",
                      "Candidate excerpt", "", literal(passage["answer_excerpt"]), "",
                      "Source excerpt", "", literal(passage["source_excerpt"]), ""]
        for ref in record["references"]:
            lines += ["Reference" + (" (permitted)" if ref["permitted"] else ""), "",
                      literal(ref["label"] + "\n" + ref["text"]), ""]
        lines += ["### Follow up", "", literal(finding["follow_up"]), "",
                  "Interviewer disposition: " + record["disposition"], "", literal(record["note"]), ""]
        if record.get("legacy"):
            lines += ["### Original native report data", "", literal(json.dumps(record["legacy"], ensure_ascii=False, indent=2)), ""]
    if session.get("legacy"):
        lines += ["## Original native session data", "", literal(json.dumps(session["legacy"], ensure_ascii=False, indent=2))]
    return "\n".join(lines)
