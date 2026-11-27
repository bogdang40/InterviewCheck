"""Portable projection of the two finding shapes retained by the first erasure writer."""
from copy import deepcopy
import json

import pytest

from api import migrate, store
from api.evidence import compare
from api.retention_anonymizer import REDACTED_TEXT, anonymized_candidate_label
from backup_requests import client, create_session, preview, restore
from test_migrate import build_native

STAMP = "2026-06-05T12:01:02.345678+00:00"
OWNER = "historical-retention-operator@example.test"
SOURCE = "Copper bearings isolate thermal stress during coastal turbine operation."
PRIVATE = "Private original statement about the turbine."


def seed_old_writer(client, tmp_path, kind):
    if kind == "native":
        original_db = tmp_path / "native.sqlite"
        build_native(original_db)
        assert migrate.migrate(original_db, store.db_path())["sessions"] == 1
        sid = migrate.portable_id("session", "i")
    else:
        sid = create_session(client)
        client.post(f"/api/sessions/{sid}/answers", json={
            "question": "Explain your check.", "answer": PRIVATE + " " + SOURCE,
            "references": [{"label": "Handbook", "text": SOURCE}],
        }).raise_for_status()

    with store.connection(write=True) as db:
        aid, raw = db.execute("SELECT id,result FROM answers WHERE session_id=?", (sid,)).fetchone()
        original = json.loads(raw)
        if kind == "native":
            assert original == migrate.ARCHIVED
        else:
            assert original["status"] == "match" and original["passages"]
            db.execute("UPDATE answers SET disposition='disclosed', note=? WHERE id=?", (PRIVATE, aid))
        # Replay the historical _scrub_result_json writer, which kept the original
        # status and comparison metadata but masked answer excerpts and quoted probes.
        saved = deepcopy(original)
        for passage in saved["passages"]:
            passage["answer_excerpt"] = REDACTED_TEXT
        if "You said" in saved["follow_up"]:
            saved["follow_up"] = REDACTED_TEXT
        db.execute("UPDATE sessions SET candidate=?, legacy=NULL WHERE id=?", (anonymized_candidate_label(sid), sid))
        db.execute("UPDATE answers SET answer=?,note='',legacy=NULL,import_origin=NULL,result=? WHERE id=?",
                   (REDACTED_TEXT, json.dumps(saved, ensure_ascii=False, separators=(",", ":")), aid))
        db.execute("INSERT INTO session_anonymizations(session_id,anonymized_at,anonymized_by) VALUES(?,?,?)",
                   (sid, STAMP, OWNER))
    # A current process opening an older database retests receipts written by that process.
    store.initialize(store.db_path())
    return sid, aid


def original_state(db, sid, aid):
    record = db.execute("SELECT CAST(result AS BLOB),status,disposition,revision FROM answers WHERE id=?", (aid,)).fetchone()
    receipt = db.execute("SELECT anonymized_at,anonymized_by FROM session_anonymizations WHERE session_id=?", (sid,)).fetchone()
    return tuple(record), tuple(receipt)


@pytest.mark.parametrize("kind", ["match", "native"])
@pytest.mark.parametrize("scope", ["interview", "workspace"])
def test_old_scrubbed_and_native_records_export_a_restorable_marker_comparison(client, tmp_path, monkeypatch, kind, scope):
    sid, aid = seed_old_writer(client, tmp_path, kind)
    source_db = store.db_path()
    with store.connection() as db:
        before = original_state(db, sid, aid)
    stored = client.get(f"/api/sessions/{sid}").raise_for_status().json()
    assert stored["privacy_state"] == "anonymized" and stored["consent"] is (kind != "native")
    assert stored["answers"][0]["result"]["status"] == ("match" if kind == "match" else "insufficient")
    scoped = client.get("/api/backups/workspace", params={"session_id": sid}).raise_for_status()
    full = client.get("/api/backups/workspace").raise_for_status()
    assert scoped.json()["sessions"] == full.json()["sessions"] and scoped.json()["roles"] == []
    # The native fixture also imports an independent role with a different title.
    assert len(full.json()["roles"]) == (1 if kind == "native" else 0)
    exported = scoped if scope == "interview" else full
    assert OWNER not in exported.text and PRIVATE not in exported.text
    session, = exported.json()["sessions"]
    answer, = session["answers"]
    assert "legacy" not in session and "legacy" not in answer and session["scorecard_items"] == []
    assert session["privacy"] == {"state": "anonymized", "anonymized_at": STAMP}
    assert answer["answer"] == REDACTED_TEXT and answer["note"] == ""
    assert answer["result"] == compare(answer["question"], REDACTED_TEXT, [])
    assert answer["result"]["status"] == "insufficient" and not answer["result"]["passages"]
    assert answer["disposition"] == ("pending" if kind == "match" else stored["answers"][0]["disposition"])
    assert preview(client, exported.content)["sessions"]["identical"] == 1
    restore(client, exported.content, preview(client, exported.content)).raise_for_status()
    with store.connection(source_db) as db:
        assert original_state(db, sid, aid) == before

    target = tmp_path / "restored.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    plan = preview(client, exported.content)
    assert plan["sessions"]["new"] == 1 and plan["conflicts"] == []
    restore(client, exported.content, plan).raise_for_status()
    recovered = client.get(f"/api/sessions/{sid}").raise_for_status().json()
    assert recovered["privacy_state"] == "anonymized" and recovered["consent"] == stored["consent"]
    restored_answer, = recovered["answers"]
    assert restored_answer["result"] == answer["result"] and restored_answer["disposition"] == answer["disposition"]
    params = {"session_id": sid} if scope == "interview" else {}
    roundtrip = client.get("/api/backups/workspace", params=params).raise_for_status()
    assert roundtrip.json() == exported.json()
    with store.connection(source_db) as db:
        assert original_state(db, sid, aid) == before

def test_ineligible_confirmed_data_cannot_download_a_file_which_the_reader_rejects(client, tmp_path):
    sid, aid = seed_old_writer(client, tmp_path, "match")
    with store.connection(write=True) as db:
        # Historical record schema can hold this value, but a consented capture cannot restore it.
        db.execute("UPDATE answers SET question='' WHERE id=?", (aid,))
    with store.connection() as db:
        before = original_state(db, sid, aid)
    for params in ({}, {"session_id": sid}):
        blocked = client.get("/api/backups/workspace", params=params)
        assert blocked.status_code == 409 and PRIVATE not in blocked.text
    with store.connection() as db:
        assert original_state(db, sid, aid) == before
