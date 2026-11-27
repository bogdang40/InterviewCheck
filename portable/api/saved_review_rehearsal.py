"""Apply the saved review rules to fixed fictional cases and scripted replies."""
from fastapi import APIRouter, Depends

from . import rate_limit, sample, saved_judge
from .evidence import compare
from .models import Reference


router = APIRouter()

SCRIPTS = (
    ("anchored", "Grounded phrase with a score", {
        "likelihood": 92, "suggestions": [{"angle": "verification", "phrase": "separate pool of workers"}],
    }),
    ("score_only", "Score without a suggestion", {
        "likelihood": 92, "confidence": "high", "evidence": [], "follow_up_questions": [],
    }),
    ("outside_excerpt", "Phrase outside the excerpt", {
        "suggestions": [{"angle": "reason", "phrase": "a different clock source"}],
    }),
)


def example(case_id, label, case, *, consent=True):
    question, answer = case["question"], case["answer"]
    references = [Reference.model_validate(source) for source in case["sources"]]
    finding = compare(question, answer, references)
    gate, payload = saved_judge.prepare_payload(question, finding, consent)
    scripts = []
    if payload is not None:
        for script_id, name, reply in SCRIPTS:
            questions = saved_judge.render_questions(reply.get("suggestions"), answer, finding["passages"])
            scripts.append({"id": script_id, "label": name, "reply": reply, "questions": questions})
    return {"id": case_id, "label": label, "question": question, "answer": answer, "notice": consent,
            "gate": gate, "comparison": finding["status"], "explanation": finding["explanation"],
            "local_question": finding["follow_up"], "payload": payload, "scripts": scripts}


@router.get("/saved-review-rehearsal", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def catalogue():
    fixtures = sample.cases()
    matched = fixtures["checkout"]
    brief = {**matched, "answer": "PostgreSQL with a unique constraint."}
    return {"cases": [
        example("brief", "A five word answer", brief),
        example("match", "A matched checkout passage", matched),
        example("permitted", "A permitted reference", fixtures["manual"]),
        example("no_source", "No comparison source", fixtures["migration"]),
        example("no_notice", "Notice not recorded", matched, consent=False),
    ]}
