"""Curated role rubric template library and safe one-click role cloning."""
import copy
import sqlite3
from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, Request
from pydantic import Field

from . import access, role_kits, role_versions, store
from .models import Input

router = APIRouter(tags=["rubric-templates"])


def _crit(cid: str, criterion: str, weight: int, signals: list[str], flags: list[str]) -> dict:
    return {"id": cid, "criterion": criterion, "weight": weight, "expected_signals": signals, "red_flags": flags}


RUBRIC_TEMPLATES = [
    {
        "id": "backend-systems",
        "title": "Backend Systems & Storage",
        "category": "Engineering",
        "summary": "Evaluates distributed state, storage durability, concurrency control, and failure recovery.",
        "default_policy": "Closed book; whiteboarding allowed for data flows; no external AI assistants.",
        "suggested_questions": [
            "How do you prevent deadlocks when multiple workers lock overlapping records?",
            "Walk through how write-ahead logging preserves durability during crash recovery.",
            "How would you bound tail latency when a downstream dependency stalls?",
        ],
        "rubric": [
            _crit("bs-architecture", "Data flow and storage design", 35,
                  ["Identifies read/write paths", "Names durability and consistency boundaries"],
                  ["Treats single-node cache as durable source of truth"]),
            _crit("bs-concurrency", "Concurrency and contention safety", 25,
                  ["Uses deterministic lock ordering or optimistic versioning", "Bounds retry storms"],
                  ["Assumes check-then-act is atomic without synchronization"]),
            _crit("bs-failure-modes", "Failure recovery and observability", 25,
                  ["Defines timeouts, backpressure, and idempotent retries"],
                  ["Retries non-idempotent mutations blindly"]),
            _crit("bs-clarity", "Tradeoff justification", 15,
                  ["States concrete latency vs consistency tradeoffs"],
                  ["Asserts zero-cost abstractions without caveats"]),
        ],
    },
    {
        "id": "frontend-accessibility",
        "title": "Frontend Architecture & Accessibility",
        "category": "Frontend",
        "summary": "Evaluates WCAG AA keyboard navigation, semantic DOM structure, and client performance.",
        "default_policy": "Standard browser docs allowed; no AI code generation assistants.",
        "suggested_questions": [
            "How do you structure focus management and ARIA roles for a multi-tab dialog?",
            "How do you diagnose and eliminate layout shift and main-thread jank on mobile?",
            "What patterns prevent stale async state from overwriting newer user input?",
        ],
        "rubric": [
            _crit("fa-semantics", "Semantic HTML and ARIA correctness", 30,
                  ["Prefers native controls before custom ARIA", "Explains live regions"],
                  ["Uses clickable div elements without keyboard handlers"]),
            _crit("fa-keyboard", "Keyboard and focus management", 25,
                  ["Handles Tab, Arrow, Home/End, and Escape flows", "Restores focus on close"],
                  ["Traps focus or removes focus outlines without replacement"]),
            _crit("fa-state", "Async state and bundle discipline", 25,
                  ["Cancels or guards stale requests", "Splits heavy views into lazy chunks"],
                  ["Ignores race conditions across rapid filter changes"]),
            _crit("fa-responsive", "Responsive layout and touch targets", 20,
                  ["Verifies 44px touch targets and zero horizontal overflow"],
                  ["Hardcodes desktop widths that clip mobile controls"]),
        ],
    },
    {
        "id": "security-threat-modeling",
        "title": "Application Security & Threat Modeling",
        "category": "Security",
        "summary": "Evaluates trust-boundary validation, auth/CSRF/SSRF controls, and secret hygiene.",
        "default_policy": "No external tools; focus on concrete attack paths and mitigations.",
        "suggested_questions": [
            "Walk through how you prevent SSRF when users configure outbound webhook URLs.",
            "How do you design session authentication and CSRF protections for state-changing APIs?",
            "How would you ensure encrypted credentials and tokens never leak in logs or exports?",
        ],
        "rubric": [
            _crit("sec-boundaries", "Trust boundary and input validation", 30,
                  ["Validates schemes, DNS resolution, and private IP ranges", "Uses allowlists"],
                  ["Relies on client-side checks or naive substring URL filters"]),
            _crit("sec-authn", "Authentication, authorization, and CSRF", 30,
                  ["Separates authentication from authorization", "Requires explicit CSRF guards"],
                  ["Skips role checks on secondary export or retry endpoints"]),
            _crit("sec-secrets", "Secret handling and error sanitization", 25,
                  ["Scrubs tokens and stack traces before returning errors or logs"],
                  ["Logs raw request headers or exception payloads verbatim"]),
            _crit("sec-verification", "Abuse testing and defense in depth", 15,
                  ["Writes negative tests for forged cookies, replay, and injection"],
                  ["Tests only happy-path authorized requests"]),
        ],
    },
    {
        "id": "production-reliability",
        "title": "Production Reliability & Incident Response",
        "category": "Operations",
        "summary": "Evaluates SLO design, circuit breaking, runbooks, and safe backup/restore drills.",
        "default_policy": "Closed book; use concrete incident timelines and recovery verification steps.",
        "suggested_questions": [
            "How do you tune circuit-breaker thresholds and cooldowns without masking real outages?",
            "Describe a backup and disaster recovery drill that proves restore integrity.",
            "Which signals belong in a readiness probe versus a liveness probe?",
        ],
        "rubric": [
            _crit("pr-probes", "Probes, SLAs, and fault isolation", 30,
                  ["Separates liveness from dependency readiness", "Tracks p95/p99 latency"],
                  ["Pages on averages while tail latency breaches SLO"]),
            _crit("pr-degradation", "Graceful degradation and failover", 25,
                  ["Uses bounded retries, circuit breakers, and fallback paths"],
                  ["Uses unbounded synchronous retries on overloaded upstreams"]),
            _crit("pr-recovery", "Backup verification and rollback", 25,
                  ["Tests restore into isolated targets and verifies schema/checksums"],
                  ["Treats unverified snapshots as working backups"]),
            _crit("pr-postmortem", "Incident communication and follow-through", 20,
                  ["Captures root cause, blast radius, and preventive guardrails"],
                  ["Blames individual operators instead of systemic gaps"]),
        ],
    },
    {
        "id": "technical-leadership",
        "title": "Technical Leadership & Cross-Team Execution",
        "category": "Leadership",
        "summary": "Evaluates architectural scoping, mentorship, risk communication, and calibration.",
        "default_policy": "Conversational walkthrough; focus on real decisions, tradeoffs, and outcomes.",
        "suggested_questions": [
            "Tell me about an architecture you simplified after shipping the first version.",
            "How did you align engineering and security stakeholders on a difficult tradeoff?",
            "How do you raise review quality and consistency across a growing team?",
        ],
        "rubric": [
            _crit("tl-scoping", "Pragmatic scoping and sequencing", 30,
                  ["Breaks ambiguous goals into verifiable milestones", "Cuts scope deliberately"],
                  ["Proposes multi-quarter rewrites without incremental validation"]),
            _crit("tl-alignment", "Stakeholder alignment and risk framing", 25,
                  ["Quantifies operational and security risks clearly", "Documents decisions"],
                  ["Hides technical debt or defers critical security constraints"]),
            _crit("tl-mentorship", "Mentorship and review standards", 25,
                  ["Gives actionable feedback", "Establishes repeatable quality bars"],
                  ["Acts as sole bottleneck instead of multiplying team capability"]),
            _crit("tl-outcomes", "Ownership and measurable impact", 20,
                  ["Cites concrete before/after metrics and lessons learned"],
                  ["Takes credit without explaining personal decision-making"]),
        ],
    },
]


class CloneRoleInput(Input):
    name: str | None = Field(default=None, min_length=1, max_length=160)
    change_note: str = Field(default="", max_length=300)


def _next_clone_name(db: sqlite3.Connection, source_name: str) -> str:
    existing = {row[0].lower() for row in db.execute("SELECT name FROM roles").fetchall()}
    suffix = " (Copy)"
    stem = source_name[: 180 - len(suffix)].rstrip() or "Role"
    candidate = f"{stem}{suffix}"
    if candidate.lower() not in existing:
        return candidate
    idx = 2
    while True:
        suffix = f" (Copy {idx})"
        stem = source_name[: 180 - len(suffix)].rstrip() or "Role"
        candidate = f"{stem}{suffix}"
        if candidate.lower() not in existing:
            return candidate
        idx += 1


@router.get("/roles/rubric-templates")
def list_rubric_templates():
    return {"templates": copy.deepcopy(RUBRIC_TEMPLATES)}


@router.post("/roles/{rid}/clone", status_code=201)
async def clone_role(rid: UUID, request: Request, item: CloneRoleInput | None = None):
    source_id = str(rid)
    _, actor_email = await access.optional_actor(request)
    with store.connection(write=True) as db:
        source = db.execute("SELECT * FROM roles WHERE id=?", (source_id,)).fetchone()
        if source is None:
            raise HTTPException(404, "Role does not exist.")
        target_name = item.name if (item is not None and item.name is not None) else _next_clone_name(db, source["name"])
        new_id = str(uuid4())
        db.execute(
            "INSERT INTO roles(id, name, description, questions, policy, permitted_sources, rubric_json, version_number) "
            "VALUES (?,?,?,?,?,?,?,1)",
            (new_id, target_name, source["description"], source["questions"],
             source["policy"], source["permitted_sources"], source["rubric_json"]),
        )
        created = db.execute("SELECT * FROM roles WHERE id=?", (new_id,)).fetchone()
        note = (item.change_note if item is not None and item.change_note else "") or f"Cloned from {source['name']}"
        role_versions.record_snapshot_row(db, created, change_note=note[:300], created_by=actor_email)
        return role_kits.role_row(created)
