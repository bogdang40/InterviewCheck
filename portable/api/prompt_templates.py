"""Versioned, admin-managed prompt templates with optimistic concurrency, diffs, and rollback."""
import difflib
import sqlite3
from typing import Annotated, Any
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BeforeValidator, Field, StringConstraints

from . import model_admin, prompt_framing, rate_limit, store
from .models import Input

SLOTS = ("question_planning", "reference_spoken", "reference_talking_points", "reference_worked_example", "judge_rubric")
DEFAULT_PROMPTS: dict[str, tuple[str, str]] = {
    "question_planning": (
        "Write six interview questions specific to the role. Include a worked example, "
        "a change of constraints and a question about the candidate's own experience.",
        "Return strictly a JSON array of question strings.",
    ),
    "reference_spoken": ("Give a short conversational answer to this interview question.", "Return plain text only."),
    "reference_talking_points": ("Give three concise points in the order someone might explain this answer aloud.", "Return plain text only."),
    "reference_worked_example": ("Answer the question with a concrete worked example and one limitation.", "Return plain text only."),
    "judge_rubric": (
        "You evaluate a job interview answer against the question, reference answers, and deterministic signals.",
        'Return strictly one JSON object with keys: "likelihood" (integer 0 to 100), '
        '"confidence" ("low", "medium", or "high"), "evidence" (array of up to 3 concise strings), '
        'and "follow_up_questions" (array of up to 2 concise strings).',
    ),
}

SCHEMA = """
CREATE TABLE IF NOT EXISTS prompt_templates (
 id TEXT PRIMARY KEY,
 slot TEXT NOT NULL UNIQUE CHECK(slot IN ('question_planning','reference_spoken','reference_talking_points','reference_worked_example','judge_rubric')),
 active_version INTEGER NOT NULL DEFAULT 1,
 system_prompt TEXT NOT NULL, output_rule TEXT NOT NULL,
 updated_by TEXT NOT NULL DEFAULT 'system', updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS prompt_template_versions (
 id TEXT PRIMARY KEY, template_id TEXT NOT NULL REFERENCES prompt_templates(id) ON DELETE CASCADE,
 version_number INTEGER NOT NULL, system_prompt TEXT NOT NULL, output_rule TEXT NOT NULL,
 change_note TEXT NOT NULL DEFAULT '', created_by TEXT NOT NULL, created_at TEXT NOT NULL,
 UNIQUE(template_id, version_number)
);
CREATE INDEX IF NOT EXISTS idx_prompt_template_versions_tpl ON prompt_template_versions(template_id, version_number DESC);
"""

router = APIRouter(prefix="/api/admin/prompts", tags=["prompt-templates"])


def migrate(db: sqlite3.Connection) -> None:
    db.executescript(SCHEMA)
    now = store.timestamp()
    for slot in SLOTS:
        if db.execute("SELECT 1 FROM prompt_templates WHERE slot=?", (slot,)).fetchone() is not None:
            continue
        system_prompt, output_rule = DEFAULT_PROMPTS[slot]
        tpl_id = str(uuid4())
        db.execute(
            "INSERT INTO prompt_templates(id,slot,active_version,system_prompt,output_rule,updated_by,updated_at) VALUES (?,?,1,?,?,'system',?)",
            (tpl_id, slot, system_prompt, output_rule, now),
        )
        db.execute(
            "INSERT INTO prompt_template_versions(id,template_id,version_number,system_prompt,output_rule,change_note,created_by,created_at) "
            "VALUES (?,?,1,?,?,'Built-in default','system',?)",
            (str(uuid4()), tpl_id, system_prompt, output_rule, now),
        )


def _ensure_ready(slot: str | None = None) -> None:
    if slot is not None and slot not in DEFAULT_PROMPTS:
        raise HTTPException(404, "Prompt template slot not found.")
    with store.connection() as db:
        tables = db.execute(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('prompt_templates','prompt_template_versions')"
        ).fetchone()[0]
        if tables == 2 and db.execute("SELECT count(*) FROM prompt_templates").fetchone()[0] >= len(SLOTS):
            return
    with store.connection(write=True) as db:
        migrate(db)


def _default_slot(slot: str) -> dict[str, Any]:
    system_prompt, output_rule = DEFAULT_PROMPTS[slot]
    return {"slot": slot, "active_version": 1, "system_prompt": system_prompt, "output_rule": output_rule, "source": "default"}


def _read_slot_from_conn(db: sqlite3.Connection, slot: str) -> dict[str, Any]:
    try:
        row = db.execute("SELECT active_version, system_prompt, output_rule FROM prompt_templates WHERE slot=?", (slot,)).fetchone()
    except sqlite3.Error:
        return _default_slot(slot)
    if row is None:
        return _default_slot(slot)
    return {"slot": slot, "active_version": int(row[0]), "system_prompt": str(row[1]), "output_rule": str(row[2]), "source": "db"}


def resolve_slot(
    slot_or_db: str | sqlite3.Connection | None = None,
    slot_arg: str | None = None,
    *,
    slot: str | None = None,
    db: sqlite3.Connection | None = None,
) -> dict[str, Any]:
    if isinstance(slot_or_db, sqlite3.Connection):
        conn, target = slot_or_db, slot_arg or slot
    elif slot_or_db is None and slot_arg is not None:
        conn, target = db, slot_arg
    else:
        conn, target = db, slot or (slot_or_db if isinstance(slot_or_db, str) else slot_arg)
    if not target or target not in DEFAULT_PROMPTS:
        raise ValueError(f"Unknown prompt template slot: {target!r}")
    if conn is not None:
        return _read_slot_from_conn(conn, target)
    db_file = store.db_path()
    if not db_file.is_file():
        return _default_slot(target)
    try:
        with store.connection(db_file) as rdb:
            return _read_slot_from_conn(rdb, target)
    except sqlite3.Error:
        return _default_slot(target)


def _clean_multiline(value: Any) -> Any:
    return prompt_framing.strip_control_chars(value, allow_newlines=True).strip() if isinstance(value, str) else value


def _clean_line(value: Any) -> Any:
    return prompt_framing.strip_control_chars(value, allow_newlines=False).strip() if isinstance(value, str) else value


class PromptUpdateInput(Input):
    system_prompt: Annotated[str, BeforeValidator(_clean_multiline), StringConstraints(min_length=10, max_length=4000)]
    output_rule: Annotated[str, BeforeValidator(_clean_line), StringConstraints(min_length=5, max_length=500)]
    change_note: Annotated[str, BeforeValidator(_clean_line), StringConstraints(min_length=0, max_length=300)] = ""
    expected_version: int = Field(ge=1)


class PromptRollbackInput(Input):
    target_version: int = Field(ge=1)
    expected_version: int = Field(ge=1)
    change_note: Annotated[str, BeforeValidator(_clean_line), StringConstraints(min_length=0, max_length=300)] = ""


def _diff_lines(system_prompt: str, output_rule: str) -> list[str]:
    return f"[system_prompt]\n{system_prompt}\n[output_rule]\n{output_rule}\n".splitlines(keepends=True)


def _unified_diff(from_p: str, from_r: str, to_p: str, to_r: str, *, from_label: str, to_label: str) -> str:
    return "".join(
        difflib.unified_diff(_diff_lines(from_p, from_r), _diff_lines(to_p, to_r), fromfile=from_label, tofile=to_label, lineterm="\n")
    )


def _template_dto(row: sqlite3.Row, version_count: int) -> dict[str, Any]:
    return {
        "id": row["id"], "slot": row["slot"], "active_version": row["active_version"],
        "system_prompt": row["system_prompt"], "output_rule": row["output_rule"],
        "updated_by": row["updated_by"], "updated_at": row["updated_at"], "version_count": version_count,
    }


def _get_tpl(db: sqlite3.Connection, slot: str, expected_version: int | None = None) -> sqlite3.Row:
    tpl = db.execute("SELECT * FROM prompt_templates WHERE slot=?", (slot,)).fetchone()
    if tpl is None:
        raise HTTPException(404, "Prompt template slot not found.")
    if expected_version is not None and int(tpl["active_version"]) != expected_version:
        raise HTTPException(409, f"Prompt template '{slot}' is at version {tpl['active_version']}, not {expected_version}.")
    return tpl


@router.get("", dependencies=[Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def list_prompts():
    _ensure_ready()
    with store.connection() as db:
        rows = db.execute(
            "SELECT t.*, (SELECT count(*) FROM prompt_template_versions v WHERE v.template_id=t.id) AS version_count FROM prompt_templates t"
        ).fetchall()
    by_slot = {row["slot"]: _template_dto(row, int(row["version_count"])) for row in rows}
    return {"prompts": [by_slot[s] for s in SLOTS if s in by_slot]}


@router.get("/{slot}/versions", dependencies=[Depends(model_admin.require_admin), Depends(rate_limit.limit(rate_limit.ADMIN_READ))])
def list_versions(slot: str):
    _ensure_ready(slot)
    with store.connection() as db:
        tpl = _get_tpl(db, slot)
        rows = db.execute("SELECT * FROM prompt_template_versions WHERE template_id=? ORDER BY version_number ASC", (tpl["id"],)).fetchall()
    versions: list[dict[str, Any]] = []
    prev: sqlite3.Row | None = None
    for row in rows:
        diff_prev = (
            _unified_diff(prev["system_prompt"], prev["output_rule"], row["system_prompt"], row["output_rule"],
                          from_label=f"v{prev['version_number']}", to_label=f"v{row['version_number']}")
            if prev is not None else ""
        )
        diff_active = _unified_diff(
            row["system_prompt"], row["output_rule"], tpl["system_prompt"], tpl["output_rule"],
            from_label=f"v{row['version_number']}", to_label=f"v{tpl['active_version']}",
        )
        versions.append({
            "id": row["id"], "template_id": row["template_id"], "version_number": row["version_number"],
            "system_prompt": row["system_prompt"], "output_rule": row["output_rule"],
            "change_note": row["change_note"], "created_by": row["created_by"], "created_at": row["created_at"],
            "is_active": row["version_number"] == tpl["active_version"],
            "diff": diff_prev, "diff_from_previous": diff_prev, "diff_vs_active": diff_active,
        })
        prev = row
    versions.reverse()
    return {"template": _template_dto(tpl, len(versions)), "versions": versions}


def _apply_new_version(
    db: sqlite3.Connection, *, tpl: sqlite3.Row, system_prompt: str, output_rule: str,
    change_note: str, actor: dict[str, Any], action: str, details: dict[str, Any], post_commit: list,
) -> dict[str, Any]:
    max_ver = db.execute("SELECT COALESCE(MAX(version_number), 0) FROM prompt_template_versions WHERE template_id=?", (tpl["id"],)).fetchone()[0]
    next_ver = max(int(tpl["active_version"]), int(max_ver)) + 1
    now, who = store.timestamp(), str(actor.get("email") or actor.get("id") or "admin")[:180]
    db.execute(
        "INSERT INTO prompt_template_versions(id,template_id,version_number,system_prompt,output_rule,change_note,created_by,created_at) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (str(uuid4()), tpl["id"], next_ver, system_prompt, output_rule, change_note, who, now),
    )
    db.execute(
        "UPDATE prompt_templates SET active_version=?, system_prompt=?, output_rule=?, updated_by=?, updated_at=? WHERE id=?",
        (next_ver, system_prompt, output_rule, who, now, tpl["id"]),
    )
    model_admin._record_audit(
        db, actor=actor, action=action, model_uuid=tpl["id"],
        details={**details, "to_version": next_ver, "change_note": change_note}, post_commit=post_commit,
    )
    updated = db.execute("SELECT * FROM prompt_templates WHERE id=?", (tpl["id"],)).fetchone()
    count = db.execute("SELECT count(*) FROM prompt_template_versions WHERE template_id=?", (tpl["id"],)).fetchone()[0]
    return _template_dto(updated, int(count))


@router.put("/{slot}", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def update_prompt(slot: str, item: PromptUpdateInput, actor: dict = Depends(model_admin.require_admin)):
    _ensure_ready(slot)
    post_commit: list = []
    with store.connection(write=True) as db:
        tpl = _get_tpl(db, slot, item.expected_version)
        prompt = _apply_new_version(
            db, tpl=tpl, system_prompt=item.system_prompt, output_rule=item.output_rule,
            change_note=item.change_note, actor=actor, action="admin.prompt.update",
            details={"slot": slot, "from_version": int(tpl["active_version"])}, post_commit=post_commit,
        )
    model_admin._flush_account_audits(post_commit)
    return {"prompt": prompt}


@router.post("/{slot}/rollback", dependencies=[Depends(rate_limit.limit(rate_limit.ADMIN_WRITE))])
def rollback_prompt(slot: str, item: PromptRollbackInput, actor: dict = Depends(model_admin.require_admin)):
    _ensure_ready(slot)
    post_commit: list = []
    with store.connection(write=True) as db:
        tpl = _get_tpl(db, slot, item.expected_version)
        target = db.execute(
            "SELECT * FROM prompt_template_versions WHERE template_id=? AND version_number=?",
            (tpl["id"], item.target_version),
        ).fetchone()
        if target is None:
            raise HTTPException(404, f"Target version {item.target_version} not found.")
        note = item.change_note or f"Rollback to version {item.target_version}"
        prompt = _apply_new_version(
            db, tpl=tpl, system_prompt=target["system_prompt"], output_rule=target["output_rule"],
            change_note=note[:300], actor=actor, action="admin.prompt.rollback",
            details={"slot": slot, "from_version": int(tpl["active_version"]), "target_version": item.target_version},
            post_commit=post_commit,
        )
    model_admin._flush_account_audits(post_commit)
    return {"prompt": prompt}
