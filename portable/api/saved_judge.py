"""Bind a model suggestion to the saved evidence and render questions from verified excerpts."""
from hashlib import sha256
import json
import re

from fastapi import HTTPException
from pydantic import Field

from . import store
from .models import Input, RequestID


class SavedJudgeInput(Input):
    session_id: RequestID
    answer_id: RequestID
    expected_revision: int = Field(ge=1)
    evidence_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


def evidence_digest(question, passages):
    # Match JSON.stringify on arrays of strings in the browser. No object key ordering is involved.
    evidence = [question, [[p["answer_excerpt"], p["source_excerpt"]] for p in passages[:3]]]
    return sha256(json.dumps(evidence, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()


def snapshot(body: SavedJudgeInput):
    with store.connection() as db:
        row = db.execute(
            """SELECT a.revision, a.question, a.answer, a.refs, a.result, s.consent, s.policy, s.candidate, s.role,
                      s.created_at, c.permitted_sources
               FROM answers a JOIN active_sessions s ON s.id=a.session_id
               LEFT JOIN session_context c ON c.session_id=s.id WHERE s.id=? AND a.id=?""",
            (str(body.session_id), str(body.answer_id)),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "Answer does not exist in this session.")
    store.check_revision(row, body.expected_revision)
    return row


def check_snapshot(body, initial):
    # A restored interview can reuse the IDs and revision of the original record.
    if snapshot(body) != initial:
        raise HTTPException(409, "This exchange or its interview changed. Reload it before requesting questions.",
                            headers={"X-InterviewCheck-Conflict": "answer-revision"})


QUESTIONS = {
    "reason": "You mentioned “{}”. What led you to that choice?",
    "verification": "You mentioned “{}”. How would you verify the result?",
    "alternative": "You mentioned “{}”. What alternative would you consider?",
    "limitation": "You mentioned “{}”. Under which conditions would your approach change?",
}
EXCERPT_LIMIT = 1000
TERM = re.compile(r"\.?\w+(?:[./'’-]\w+)*(?:\+\+|#)?")
PHRASE = re.compile(rf"{TERM.pattern}(?: {TERM.pattern}){{0,7}}")
OUTPUT_RULE = (
    'Return one JSON object with "suggestions", an array of up to two objects. For each, select an "angle" '
    'from reason, verification, alternative, or limitation, and a "phrase" of one to eight consecutive words '
    'copied exactly from an answer_excerpt. Select a technical choice or action the candidate can explain. '
    'Omit scores, assessments of conduct, and question text.'
)


def _contains_sent_phrase(answer, passage, phrase):
    excerpt = passage["answer_excerpt"]
    span = passage.get("answer_span")
    if span is None:
        # Older findings have no offsets. Use only an excerpt with one possible location.
        start = answer.find(excerpt)
        if start < 0 or answer.find(excerpt, start + 1) >= 0:
            return False
    else:
        start, end = span
        if start < 0 or start + len(excerpt) > end or not answer.startswith(excerpt, start):
            return False
    limit = start + min(len(excerpt), EXCERPT_LIMIT)
    starts, ends = [], set()
    # Both the matcher's excerpt and the send limit can stop inside a technical term.
    for term in TERM.finditer(answer):
        if term.end() > limit:
            break
        if term.start() < start:
            continue
        starts.append(term.start())
        ends.add(term.end())
    return any(pos + len(phrase) in ends and answer.startswith(phrase, pos) for pos in starts)


def render_questions(value, answer, passages):
    if not isinstance(value, list):
        return []
    questions = []
    for item in value[:2]:
        if not isinstance(item, dict):
            continue
        angle, phrase = item.get("angle"), item.get("phrase")
        if not isinstance(angle, str) or angle not in QUESTIONS or not isinstance(phrase, str):
            continue
        if not 1 <= len(phrase) <= 90 or not PHRASE.fullmatch(phrase):
            continue
        if any(_contains_sent_phrase(answer, passage, phrase) for passage in passages[:3]):
            question = QUESTIONS[angle].format(phrase)
            if question not in questions:
                questions.append(question)
    return questions
