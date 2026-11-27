"""A worksheet grants no access and carries no authority to replace saved evidence."""
import json

from fastapi.testclient import TestClient
import pytest

from api import rate_limit, store
from api.main import app
from api.retention_anonymizer import SessionAnonymizer


@pytest.fixture
def web(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    rate_limit.reset_all()
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        yield client


def exchange(web):
    s = web.post("/api/sessions", json={"candidate": "Private person", "role": "Developer",
                                        "policy": "Sample policy", "consent": True})
    s.raise_for_status()
    sid = s.json()["id"]
    ids = []
    for _ in range(2):
        a = web.post(f"/api/sessions/{sid}/answers", json={"question": "Explain the decision.",
                                                           "answer": "A specific answer.", "references": []})
        a.raise_for_status()
        ids.append(a.json()["id"])
    return sid, ids


def read(web, sid, aid):
    res = web.get(f"/api/sessions/{sid}/answers/{aid}/worksheet")
    res.raise_for_status()
    return res.json()


def apply(web, sid, aid, state, *, note="Reviewed the decision.", disposition=None):
    return web.patch(f"/api/sessions/{sid}/answers/{aid}", json={
        "note": note, "disposition": disposition or state["answer"]["disposition"],
        "expected_revision": state["answer"]["revision"],
        "worksheet_guard": {"material": state["material"], "review": state["review"]},
    })


def test_return_metadata_distinguishes_identical_prompts_and_does_not_cast_a_vote(web):
    sid, (a, b) = exchange(web)
    first, second = read(web, sid, a), read(web, sid, b)
    assert (first["ordinal"], second["ordinal"]) == (1, 2)
    assert first["material"] != second["material"]
    assert apply(web, sid, b, first).status_code == 409
    # This review belongs to a different actor. Saving a worksheet can change only the note.
    with store.connection(write=True) as db:
        db.execute("UPDATE answers SET disposition='explained' WHERE id=?", (b,))
    latest = read(web, sid, b)
    assert apply(web, sid, b, latest, disposition="unresolved").status_code == 409
    saved = apply(web, sid, b, latest)
    saved.raise_for_status()
    assert saved.json()["disposition"] == "explained"
    assert apply(web, sid, b, latest).status_code == 409
    read_again = read(web, sid, b)
    assert read_again["material"] == latest["material"] and read_again["review"] != latest["review"]
    assert apply(web, sid, b, read_again).json()["revision"] == saved.json()["revision"]
    with store.connection() as db:
        assert db.execute("SELECT COUNT(*) FROM answer_review_events WHERE answer_id=?", (b,)).fetchone()[0] == 0


@pytest.mark.parametrize("change", ["question", "answer", "review", "identity", "policy"])
def test_same_ids_and_revision_cannot_authorize_replaced_content(web, change):
    sid, (aid, _) = exchange(web)
    seen = read(web, sid, aid)
    with store.connection(write=True) as db:
        if change == "identity":
            db.execute("UPDATE sessions SET candidate='A different candidate' WHERE id=?", (sid,))
        elif change == "policy":
            db.execute("UPDATE sessions SET policy='A different policy' WHERE id=?", (sid,))
        elif change == "review":
            db.execute("UPDATE answers SET note='A different reviewed note' WHERE id=?", (aid,))
        elif change == "question":
            db.execute("UPDATE answers SET question='A different question?' WHERE id=?", (aid,))
        else:
            db.execute("UPDATE answers SET answer='Different evidence' WHERE id=?", (aid,))
    assert apply(web, sid, aid, seen).status_code == 409
    assert read(web, sid, aid)["answer"]["note"] != "Reviewed the decision."


def test_different_workspace_rejects_identical_json_restoration(web, tmp_path, monkeypatch):
    sid, (aid, _) = exchange(web)
    original = read(web, sid, aid)
    raw = web.get("/api/backups/workspace", params={"session_id": sid}).content
    target = tmp_path / "recovered.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    preview = web.post("/api/backups/preview", content=raw, headers={"Content-Type": "application/json"})
    preview.raise_for_status()
    web.post("/api/backups/restore", content=raw, headers={"Content-Type": "application/json",
             "X-Backup-Preview": preview.json()["fingerprint"]}).raise_for_status()
    restored = read(web, sid, aid)
    assert restored["session"] == original["session"] and restored["answer"] == original["answer"]
    assert restored["material"] != original["material"]
    assert apply(web, sid, aid, original).status_code == 409
    store.initialize(target)
    assert read(web, sid, aid)["material"] == restored["material"]


@pytest.mark.parametrize("mode", ["trash", "retention", "legacy_redaction", "notice"])
def test_erasure_and_lost_notice_block_preview_and_save(web, mode):
    sid, (aid, _) = exchange(web)
    view = read(web, sid, aid)
    if mode == "trash":
        web.post(f"/api/sessions/{sid}/trash").raise_for_status()
        expected = 404
    else:
        expected = 403
        with store.connection(write=True) as db:
            if mode == "notice":
                db.execute("UPDATE sessions SET consent=0 WHERE id=?", (sid,))
            else:
                SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=True,
                                               actor_email="fixture@example.test", now_iso=store.timestamp())
                if mode == "legacy_redaction":
                    db.execute("DELETE FROM session_anonymizations WHERE session_id=?", (sid,))
    assert web.get(f"/api/sessions/{sid}/answers/{aid}/worksheet").status_code == expected
    assert apply(web, sid, aid, view).status_code == expected


def test_preview_is_read_only_and_binding_key_never_leaves_database(web):
    sid, (aid, _) = exchange(web)
    with store.connection() as db:
        key = db.execute("SELECT binding_key FROM worksheet_workspace").fetchone()[0]
        before = store.get_answer(db, sid, aid)
    first = read(web, sid, aid)
    assert first == read(web, sid, aid)
    assert key.hex() not in json.dumps(first)
    backup = web.get("/api/backups/workspace")
    assert key.hex() not in backup.text and "worksheet_workspace" not in backup.text
    with store.connection() as db:
        assert store.get_answer(db, sid, aid) == before
