"""An older physical database can contain a review saved after confirmed erasure."""
from copy import deepcopy
import json
from uuid import uuid4

import pytest

from api import answer_history, retention_policy, search_fts, store
from api.retention_anonymizer import REDACTED_TEXT, SessionAnonymizer
from backup_requests import client, create_session


STAMP = "2026-04-12T08:30:00+00:00"
OWNER = "retention-owner@example.test"
MARKER = "distinctive old review text"


def retained(client):
    sid = create_session(client)
    path = f"/api/sessions/{sid}"
    aid = client.post(path + "/answers", json={"question": "Describe the measurement.",
                      "answer": "Measure a sample twice."}).raise_for_status().json()["id"]
    with store.connection(write=True) as db:
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=True, actor_email=OWNER, now_iso=STAMP)
    return sid, aid


def receipt(db, sid):
    return tuple(db.execute("SELECT anonymized_at,anonymized_by FROM session_anonymizations WHERE session_id=?",
                            (sid,)).fetchone())


@pytest.mark.parametrize("older_state", ["current_note", "history_only", "answer_text", "finding",
                                        "follow_up", "unprefixed_follow_up", "explanation"])
def test_upgrade_withholds_each_conflicting_record_without_changing_its_contents(client, monkeypatch, older_state):
    sid, aid = retained(client)
    clean, _ = retained(client)
    unrelated = create_session(client)
    path = f"/api/sessions/{sid}"
    exchange = path + "/answers/" + aid
    with store.connection(write=True) as db:
        # The old physical format includes the revision history. A JSON round trip cannot model this case.
        if older_state == "history_only":
            snapshot = deepcopy(store.get_answer(db, sid, aid))
            snapshot["note"] = MARKER
            answer_history.record(db, snapshot, "review_update", saved_at=store.timestamp())
        elif older_state == "current_note":
            db.execute("UPDATE answers SET note=? WHERE id=?", (MARKER, aid))
        elif older_state == "answer_text":
            db.execute("UPDATE answers SET answer=? WHERE id=?", (MARKER, aid))
        else:
            found = store.get_answer(db, sid, aid)["result"]
            if older_state == "finding":
                found["passages"] = [{"answer_excerpt": MARKER}]
            elif older_state == "follow_up":
                found["follow_up"] = f"You said “{MARKER}”. Give an example."
            elif older_state == "unprefixed_follow_up":
                found["follow_up"] = MARKER
            else:
                found["explanation"] = MARKER
            db.execute("UPDATE answers SET result=? WHERE id=?", (json.dumps(found), aid))
        before = tuple(db.execute("SELECT * FROM answers WHERE id=?", (aid,)).fetchone())
        history = db.execute("SELECT snapshot FROM answer_history WHERE answer_id=?", (aid,)).fetchall()
    # Later writes from a still-open older database connection are withheld at commit as well.
    assert client.get(path + "/report").status_code == 409
    for _ in range(2):
        store.initialize(store.db_path())
    assert retention_policy.get_retention_policy()["withheld_interviews"] == 1
    for endpoint in (path, path + "/report", path + "/print", exchange, exchange + "/history",
                     exchange + "/history/2", path + "/draft", path + "/scorecard", path + "/handoff-notes"):
        res = client.get(endpoint)
        assert res.status_code == 409 and MARKER not in res.text, endpoint
    for endpoint, body in ((path + "/brief", {"note_ids": [aid], "excerpt_ids": [aid]}),
                           (path + "/brief/download", {"note_ids": [aid], "preview_sha256": "0"*64}),
                           ("/api/interviews/compare", {"session_ids": [clean, sid], "include_notes": True}),
                           ("/api/interviews/compare/dossier", {"session_ids": [clean, sid], "format": "markdown"}),
                           ("/api/interviews/bulk/export", {"session_ids": [sid, clean], "format": "json"}),
                           ("/api/interviews/bulk/export", {"session_ids": [sid], "format": "csv"})):
        res = client.post(endpoint, json=body)
        assert res.status_code == 409 and MARKER not in res.text
    assert client.get("/api/interviews/compare/print", params={"ids": f"{clean},{sid}"}).status_code == 409
    assert client.get("/api/exports/interviews.csv").status_code == 409
    assert client.get("/api/backups/workspace").status_code == 409
    assert client.get("/api/backups/workspace", params={"session_id": sid}).status_code == 409
    for fallback in (False, True):
        if fallback:
            monkeypatch.setattr(search_fts, "has_fts", lambda db: False)
        search = client.post("/api/search", json={"query": MARKER, "kinds": ["answer"], "cursor": "", "limit": 1})
        assert search.raise_for_status().json() == {"items": [], "has_more": False, "next_cursor": None}
    assert {s["id"] for s in client.get("/api/sessions").raise_for_status().json()} == {clean, unrelated}
    assert REDACTED_TEXT in client.get(f"/api/sessions/{clean}/report").raise_for_status().text
    client.get("/api/backups/workspace", params={"session_id": unrelated}).raise_for_status()
    with store.connection() as db:
        assert receipt(db, sid) == (STAMP, OWNER)
        assert tuple(db.execute("SELECT * FROM answers WHERE id=?", (aid,)).fetchone()) == before
        assert db.execute("SELECT snapshot FROM answer_history WHERE answer_id=?", (aid,)).fetchall() == history


def test_withheld_record_in_trash_cannot_restore_or_reveal_a_disputed_candidate(client):
    sid, _ = retained(client)
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET candidate=? WHERE id=?", (MARKER, sid))
    client.post(f"/api/sessions/{sid}/trash").raise_for_status()
    store.initialize(store.db_path())
    entry, = client.get("/api/trash").raise_for_status().json()["items"]
    assert entry["id"] == sid and entry["candidate"] == "Protected interview" and entry["role"] == ""
    response = client.post(f"/api/trash/{sid}/restore", json={"operation_version": entry["operation_version"]})
    assert response.status_code == 409 and MARKER not in response.text
    with store.connection() as db:
        assert receipt(db, sid) == (STAMP, OWNER)
        assert db.execute("SELECT 1 FROM session_trash WHERE session_id=?", (sid,)).fetchone()
    client.get("/api/exports/interviews.csv").raise_for_status()
    assert client.get("/api/backups/workspace").status_code == 409


@pytest.mark.parametrize("preserve", [False, True])
def test_a_clean_receipt_keeps_the_original_grade_and_handoff_policy(client, preserve):
    sid = create_session(client)
    path = f"/api/sessions/{sid}"
    nid = str(uuid4())
    with store.connection(write=True) as db:
        db.execute("""INSERT INTO session_handoff_notes(id,session_id,author_email,category,body,created_at)
                      VALUES(?,?,?,'observation',?,?)""", (nid, sid, OWNER, "Retained panel context", STAMP))
        db.execute("""INSERT INTO session_scorecards(session_id,criterion_id,criterion_label,weight,rating,
                      rationale,updated_by,updated_at) VALUES(?,'test','Testing',2,4,?,?,?)""",
                   (sid, "Basis of the grade", OWNER, STAMP))
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=preserve, actor_email=OWNER, now_iso=STAMP)
    store.initialize(store.db_path())
    assert retention_policy.get_retention_policy()["withheld_interviews"] == 0
    card = client.get(path + "/scorecard").raise_for_status().json()
    note, = card["handoff_notes"]
    assert (note["id"], note["author_email"], note["created_at"]) == (nid, OWNER, STAMP)
    assert note["body"] == ("Retained panel context" if preserve else "")
    row, = card["items"]
    assert (row["weight"], row["rating"], row["updated_by"]) == (2, 4, OWNER)
    assert row["rationale"] == ("Basis of the grade" if preserve else "")
    client.get(path + "/report").raise_for_status()


@pytest.mark.parametrize("recreate_old_view", [False, True])
def test_recovery_reinstalls_missing_or_changed_visibility_objects(client, recreate_old_view):
    sid, aid = retained(client)
    with store.connection(write=True) as db:
        db.execute("DROP VIEW active_sessions")
        if recreate_old_view:
            db.execute("""CREATE VIEW active_sessions AS SELECT s.rowid AS rowid,s.* FROM sessions s
                       WHERE NOT EXISTS (SELECT 1 FROM session_trash t WHERE t.session_id=s.id)""")
        db.execute("DROP TRIGGER retention_hold_answers_UPDATE")
        db.execute("CREATE TRIGGER retention_hold_answers_UPDATE AFTER UPDATE ON answers BEGIN SELECT 1; END")
        db.execute("UPDATE answers SET note=? WHERE id=?", (MARKER, aid))
        assert not db.execute("SELECT 1 FROM retention_read_holds WHERE session_id=?", (sid,)).fetchone()
    for _ in range(2):
        store.initialize(store.db_path())
        assert client.get(f"/api/sessions/{sid}/report").status_code == 409
        assert client.get("/api/exports/interviews.csv").status_code == 409
        assert client.get("/api/sessions").raise_for_status().json() == []
    other, other_aid = retained(client)
    with store.connection(write=True) as db:
        db.execute("UPDATE answers SET note=? WHERE id=?", (MARKER, other_aid))
    assert client.get(f"/api/sessions/{other}/report").status_code == 409
