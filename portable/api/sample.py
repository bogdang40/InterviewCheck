"""The fictional sample review's comparison, open to visitors who are not signed in.

It never accepts text: the caller names one of the fixed cases in sample_cases.json and which
of its sources are permitted, and the server compares that fixture exactly as /api/preview would.
The hosted home page links here, so the sample has to work before sign-in.
"""
import json
from functools import cache
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import Field

from . import rate_limit
from .evidence import compare
from .models import Input, Reference

CASES = Path(__file__).with_name("sample_cases.json")

router = APIRouter(prefix="/api/sample", dependencies=[Depends(rate_limit.limit(rate_limit.SAMPLE_PREVIEW))])


@cache
def cases() -> dict[str, dict]:
    data = json.loads(CASES.read_text(encoding="utf-8"))
    return {case["id"]: case for case in data["cases"]}


class SamplePreview(Input):
    case_id: str = Field(min_length=1, max_length=40)
    permitted: list[bool] = Field(default_factory=list, max_length=8)


@router.post("/preview")
def sample_preview(item: SamplePreview):
    case = cases().get(item.case_id)
    if case is None:
        raise HTTPException(404, "There is no sample case with this name.")
    sources = case["sources"]
    if item.permitted and len(item.permitted) != len(sources):
        raise HTTPException(422, "Send one permitted flag for each sample source.")
    flags = item.permitted or [source["permitted"] for source in sources]
    references = [Reference(label=s["label"], text=s["text"], permitted=flag) for s, flag in zip(sources, flags)]
    return compare(case["question"], case["answer"], references)
