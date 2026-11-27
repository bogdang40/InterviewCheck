"""Verify relationships, native compatibility and evidence before writing a restored record."""

from datetime import datetime
from uuid import UUID

from .evidence import Words, compare
from .role_kits import content_version
from .lineage import validate_graph
from .retained_finding import recognized_text
from .session_privacy import archive_only_erasure
from .models import AnswerInput, Reference, RoleInput, SessionInput, validate_note_length


def check_session_chronology(created_at: str, ended_at: str | None, trashed_at: str | None) -> None:
    created = datetime.fromisoformat(created_at)
    if ended_at is not None and datetime.fromisoformat(ended_at) < created:
        raise ValueError("Session ended_at cannot precede created_at.")
    if trashed_at is not None and datetime.fromisoformat(trashed_at) < created:
        raise ValueError("Session trashed_at cannot precede created_at.")


def verify_finding(answer, session, inherited_grams, *, erased_archive=False):
    finding = answer.result
    confirmed = session.privacy is not None and session.privacy.state == "anonymized"
    if confirmed and not recognized_text(finding.explanation, finding.follow_up):
        raise ValueError("The confirmed anonymization contains unrecognized finding text.")
    if answer.disposition == "disclosed" and not answer.note.strip():
        raise ValueError("Missing disclosure note.")
    if answer.import_origin:
        origin = answer.import_origin
        from .transcript_import import exchange_id

        if (
            origin.interviewer_speakers != sorted(set(origin.interviewer_speakers))
            or origin.candidate_speaker in origin.interviewer_speakers
            or (origin.first_cue is None) != (origin.last_cue is None)
            or (origin.first_cue is not None and origin.last_cue < origin.first_cue)
            or str(exchange_id(UUID(session.id), origin.model_dump(exclude_none=True))) != answer.id
        ):
            raise ValueError("Transcript provenance does not identify this exchange.")
    if finding.archived:
        from .migrate import ARCHIVED

        if answer.legacy is None or finding.model_dump(exclude_none=True) != ARCHIVED:
            raise ValueError("Invalid historical finding.")
        return
    if erased_archive:
        # The retained marker is shorter than a match. Native questions and source
        # lists can exceed capture limits. Verify the newly computed finding.
        expected = compare(answer.question, answer.answer, [])
        if confirmed:
            # An older writer may have scrubbed this prompt to the fixed marker. Its text
            # has already been checked above. Keep all structural evidence checks.
            expected["follow_up"] = finding.follow_up
        if finding.model_dump(exclude_none=True) != expected:
            raise ValueError("Invalid comparison for the retained archive exchange.")
        return
    if len(answer.answer) > 24000 or len(answer.question) > 4000 or len(answer.references) > 12:
        raise ValueError("An exchange exceeds the comparison limits.")
    refs = [Reference(**r.model_dump()) for r in answer.references]
    historical = all(
        p.source_index is None and p.source_span is None and p.answer_span is None for p in finding.passages
    )
    result = compare(
        answer.question, answer.answer, refs, inherited_grams=inherited_grams, legacy_labels=historical
    )
    if (
        finding.status != result["status"]
        or finding.explanation != result["explanation"]
        or len(finding.passages) != len(result["passages"])
    ):
        raise ValueError("A stored finding disagrees with its evidence.")
    for passage, computed in zip(finding.passages, result["passages"]):
        recorded = passage.model_dump(exclude_none=True)
        if not historical and any(
            v is None for v in (passage.source_index, passage.answer_span, passage.source_span)
        ):
            raise ValueError("A quoted passage cannot be verified against its sources.")
        if not all(computed.get(key) == value for key, value in recorded.items()):
            raise ValueError("A quoted passage cannot be verified against its sources.")


def unique(items, name):
    seen = set()
    for item in items:
        if item in seen:
            raise ValueError("Duplicate " + name + ".")
        seen.add(item)
    return seen


def verify_rubric_sources(backup):
    snapshots = [s.rubric_snapshot for s in backup.sessions if s.rubric_snapshot and s.rubric_snapshot.role_id]
    requested = {(snap.role_id, snap.version_number) for snap in snapshots}
    sources = {}
    for role in backup.roles:
        for version in (role, *role.versions):
            key = (role.id, version.version_number)
            if key not in requested:
                continue
            fields = version.model_dump(include={"name", "description", "questions", "policy", "permitted_sources", "rubric"})
            digest = content_version({"id": role.id, **fields})
            if version is not role and version.content_sha256 != digest:
                raise ValueError("An archived role version disagrees with its recorded content digest.")
            if key in sources and sources[key][0] != digest:
                raise ValueError("The archive gives different definitions for the same role revision.")
            sources[key] = (digest, version.rubric)
    for snap in snapshots:
        source = sources.get((snap.role_id, snap.version_number))
        # Detached and older versions can be absent. Compare only when the file supplies the original.
        if source is not None and (snap.role_content_sha256, snap.criteria) != source:
            raise ValueError("An interview rubric disagrees with the archived role revision.")


def verify_records(backup):
    if backup.version >= 6:
        verify_rubric_sources(backup)
    roles = unique((r.id for r in backup.roles), "role ID")
    for role in backup.roles:
        if role.legacy is None:
            RoleInput.model_validate(role.model_dump(exclude={"legacy"}))
    unique((s.id for s in backup.sessions), "interview ID")
    published = unique((a.id for s in backup.sessions for a in s.answers), "exchange ID")
    saved = unique((s.draft.id for s in backup.sessions if s.draft), "draft ID")
    if published & saved:
        raise ValueError("An exchange and draft have the same ID.")
    for session in backup.sessions:
        check_session_chronology(session.created_at, session.ended_at, session.trashed_at)
        validate_graph(session.planned_questions, session.answers, session.draft)
        erased_archive = archive_only_erasure(session)
        if session.legacy is None and not erased_archive:
            SessionInput.model_validate(
                session.model_dump(
                    include={
                        "id",
                        "candidate",
                        "role",
                        "role_id",
                        "policy",
                        "consent",
                        "permitted_sources",
                    }
                )
            )
            if len(session.planned_questions) > 100 or any(
                not q.strip() or len(q) > 4000 for q in session.planned_questions
            ):
                raise ValueError("Invalid planned questions.")
        if session.draft:
            from .drafts import DraftInput

            draft = DraftInput.model_validate(
                {**session.draft.model_dump(exclude={"revision", "updated_at"}), "expected_revision": 0}
            )
            if (
                not session.consent
                or session.ended_at
                or not (draft.answer or draft.question or any(r.label or r.text for r in draft.references))
            ):
                raise ValueError("Invalid saved draft.")
        if session.role_id and session.role_id not in roles:
            raise ValueError("An interview refers to a missing role.")
        # A large permitted manual is the same for every exchange in this session.
        inherited_grams = set()
        if not erased_archive and any(a.references and not a.result.archived for a in session.answers):
            for ref in session.permitted_sources:
                inherited_grams.update(Words(ref.text).grams(4))
        for answer in session.answers:
            if answer.legacy is None and not erased_archive:
                AnswerInput.model_validate(
                    answer.model_dump(include={"id", "question", "answer", "references"})
                )
                validate_note_length(answer.note)
            if answer.import_origin and answer.import_origin.end_ms < answer.import_origin.start_ms:
                raise ValueError("The transcript interval is invalid.")
            verify_finding(answer, session, inherited_grams, erased_archive=erased_archive)
