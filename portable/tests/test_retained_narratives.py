"""Preserved notes and rationales must already have existed at confirmed erasure."""
from contextlib import closing
from hashlib import sha256
import json
import sqlite3

import pytest

from api import access, retained_narratives, session_privacy, store
from api.retention_anonymizer import SessionAnonymizer
from backup_requests import client, create_session, preview, restore

RECEIPT = "2026-03-11T00:00:00.123456700Z"
BEFORE = "2026-03-11T10:30:00.123456699+10:30"
EQUAL = "2026-03-10T17:00:00.123456700-07:00"
AFTER = "2026-03-10T17:00:00.123456701-07:00"
AUTHOR = "first-panelist@fixture.example"


def fixture(client, monkeypatch, *, preserve=True, note_time=BEFORE, grade_time=EQUAL):
    async def actor(_):
        return "first-panelist", AUTHOR

    monkeypatch.setattr(access, "optional_actor", actor)
    monkeypatch.setattr(store, "timestamp", lambda: "2026-03-01T12:00:00+00:00")
    sid = create_session(client)
    path = "/api/sessions/" + sid
    monkeypatch.setattr(store, "timestamp", lambda: note_time)
    note = client.post(path + "/handoff-notes", json={"category": "decision", "body": "Original handoff."}).raise_for_status().json()
    monkeypatch.setattr(store, "timestamp", lambda: grade_time)
    card = client.put(path + "/scorecard", json={"items": [{"criterion_id": "method", "criterion_label": "Method",
                      "weight": 3, "rating": 4, "rationale": "Original rationale."}]}).raise_for_status().json()
    with store.connection(write=True) as db:
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=preserve,
                                       actor_email="retention@fixture.example", now_iso=RECEIPT)
    return sid, note, card["items"][0]


def fresh(tmp_path, monkeypatch):
    path = tmp_path / "restored.sqlite3"
    store.initialize(path)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(path))


@pytest.mark.parametrize("preserve", [True, False])
def test_valid_narrative_ids_timestamps_and_actors_survive_receipt_restore(client, monkeypatch, tmp_path, preserve):
    # With narrative preservation off, only metadata survives and its time cannot disclose a new narrative.
    sid, note, grade = fixture(client, monkeypatch, preserve=preserve,
                               note_time=BEFORE if preserve else AFTER, grade_time=EQUAL if preserve else AFTER)
    raw = client.get("/api/backups/workspace").raise_for_status().content
    doc = json.loads(raw)["sessions"][0]
    assert doc["privacy"] == {"state": "anonymized", "anonymized_at": RECEIPT}
    assert doc["handoff_notes"][0]["body"] == ("Original handoff." if preserve else "")
    assert doc["scorecard_items"][0]["rationale"] == ("Original rationale." if preserve else "")
    fresh(tmp_path, monkeypatch)
    restore(client, raw, preview(client, raw)).raise_for_status()
    for _ in range(2):
        state = client.get(f"/api/sessions/{sid}/scorecard").raise_for_status().json()
        only_note, = state["handoff_notes"]
        marked, = state["items"]
        assert only_note == {**note, "body": "Original handoff." if preserve else ""}
        assert (marked["rating"], marked["weight"], marked["rationale"], marked["updated_by"], marked["updated_at"]) == (
            4, 3, "Original rationale." if preserve else "", AUTHOR, grade["updated_at"])
        assert only_note["author_email"] == AUTHOR
        with store.connection() as db:
            assert not db.execute("SELECT 1 FROM retention_read_holds WHERE session_id=?", (sid,)).fetchone()
        store.initialize(store.db_path())


@pytest.mark.parametrize(("group", "stamp_field"), [("handoff_notes", "created_at"), ("scorecard_items", "updated_at")])
def test_v6_rejects_later_narrative_on_preview_and_on_fresh_restore(client, monkeypatch, tmp_path, group, stamp_field):
    fixture(client, monkeypatch)
    doc = client.get("/api/backups/workspace").raise_for_status().json()
    doc["sessions"][0][group][0][stamp_field] = AFTER
    raw = json.dumps(doc).encode()
    fresh(tmp_path, monkeypatch)
    for reply in (client.post("/api/backups/preview", content=raw),
                  restore(client, raw, {"fingerprint": sha256(raw).hexdigest()})):
        assert reply.status_code == 422
        assert "Original rationale." not in reply.text and "Original handoff." not in reply.text
    assert client.get("/api/sessions").raise_for_status().json() == []


def test_new_receipt_with_preexisting_later_text_immediately_holds_the_interview(client, monkeypatch):
    sid, _, _ = fixture(client, monkeypatch, note_time=AFTER)
    assert client.get(f"/api/sessions/{sid}/report").status_code == 409
    with store.connection() as db:
        assert session_privacy.read(db, sid).anonymized_at == RECEIPT
        retained = db.execute("SELECT body,author_email FROM session_handoff_notes WHERE session_id=?", (sid,)).fetchone()
        assert tuple(retained) == ("Original handoff.", AUTHOR)


def test_upgrade_selects_only_later_or_unverifiable_nonempty_narratives_and_preserves_rows():
    # Isolate preexisting data from runtime triggers, which protect fresh writes independently.
    with closing(sqlite3.connect(":memory:")) as db:
        db.executescript("""CREATE TABLE session_anonymizations(session_id TEXT PRIMARY KEY,anonymized_at TEXT);
            CREATE TABLE legacy_privacy_holds(session_id TEXT PRIMARY KEY);
            CREATE TABLE retention_read_holds(session_id TEXT PRIMARY KEY);
            CREATE TABLE session_handoff_notes(session_id TEXT,body TEXT,created_at TEXT);
            CREATE TABLE session_scorecards(session_id TEXT,rationale TEXT,updated_at TEXT);""")
        pairs = [(name, RECEIPT) for name in ("early", "equal", "note", "grade", "empty", "bad")] + [("oversize", "0" * 65)]
        db.executemany("INSERT INTO session_anonymizations VALUES(?,?)", pairs)
        db.execute("INSERT INTO legacy_privacy_holds VALUES('legacy')")
        db.executemany("INSERT INTO session_handoff_notes VALUES(?,?,?)", [
            ("early", "Before", BEFORE), ("note", "Later", AFTER), ("empty", "", AFTER),
            ("legacy", "Unverified legacy", AFTER), ("oversize", "Unverified clock", BEFORE)])
        db.executemany("INSERT INTO session_scorecards VALUES(?,?,?)", [
            ("equal", "Same instant", EQUAL), ("grade", "Later", AFTER), ("bad", "Unknown", "not a timestamp")])
        for _ in range(2):
            retained_narratives.refresh(db)
            assert {r[0] for r in db.execute("SELECT session_id FROM retention_read_holds")} == {"note", "grade", "bad", "oversize"}
        assert db.execute("SELECT rationale,updated_at FROM session_scorecards WHERE session_id='grade'").fetchone() == ("Later", AFTER)
        assert db.execute("SELECT count(*) FROM legacy_privacy_holds").fetchone() == (1,)


@pytest.mark.parametrize(("earlier", "later"), [
    ("2026-03-10T23:59:59.999999999Z", "2026-03-11T05:30:00.000000000+05:30"),
    ("2026-03-11T00:00:00Z", "2026-03-10T16:00:00.000000001-08:00"),
    ("2026-03-11T00:00:00+00:00:00.000000002", "2026-03-11T00:00:00+00:00:00.000000001"),
    ("2026-03-11T00:00:00-00:00:00.000000001", "2026-03-11T00:00:00-00:00:00.000000002"),
])
def test_fractional_utc_comparisons_remain_exact_across_second_boundaries(earlier, later):
    assert retained_narratives._instant(earlier) < retained_narratives._instant(later)
