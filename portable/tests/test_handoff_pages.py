import base64
from contextlib import contextmanager
import sqlite3
from uuid import UUID, uuid4

from api import store
from backup_requests import client, create_session


STAMP = "2025-02-11T09:08:07.654321-07:00"


def key(index):
    return str(UUID(int=index))


def insert(db, sid, index, category="follow_up", stamp=STAMP, body=None, author=None):
    row = {"id": key(index), "session_id": sid, "category": category, "created_at": stamp,
           "body": f"Private body {index}" if body is None else body, "author_email": author or f"author{index}@example.test"}
    db.execute("""INSERT INTO session_handoff_notes(id,session_id,category,body,author_email,created_at)
                  VALUES(:id,:session_id,:category,:body,:author_email,:created_at)""", row)
    return row


def test_pages_use_exact_stored_order_and_survive_deleted_anchor(client):
    sid, other = create_session(client), create_session(client)
    url = f"/api/sessions/{sid}/handoff-notes"
    with store.connection(write=True) as db:
        for index in range(1, 10):
            insert(db, sid, index, category="decision" if index == 6 else "follow_up")
        # The existing scorecard orders by stored timestamp text, including its offset.
        insert(db, sid, 11, stamp="2025-02-11T10:08:07.654321+01:00")
        insert(db, other, 12)
    first = client.get(url, params={"category": "follow_up", "limit": 3}).raise_for_status().json()
    assert first["total"] == 9 and [n["id"] for n in first["items"]] == [key(11), key(9), key(8)]
    assert first["next_cursor"]
    token = first["next_cursor"]
    decoded = base64.urlsafe_b64decode(token + "=" * (-len(token) % 4))
    for private in (b"Private body", b"@example.test", sid.encode(), b"follow_up"):
        assert private not in decoded
    client.delete(f"{url}/{key(8)}").raise_for_status()
    added = client.post(url, json={"category": "follow_up", "body": "Just added"}).raise_for_status().json()
    after = client.get(url, params={"limit": 50, "category": "follow_up", "cursor": token}).raise_for_status().json()
    assert after["total"] == 9 and after["next_cursor"] is None
    assert [n["id"] for n in after["items"]] == [key(i) for i in (7, 5, 4, 3, 2, 1)]
    assert all(n["session_id"] == sid and n["category"] == "follow_up" and n["id"] != added["id"] for n in after["items"])
    score = client.get(f"/api/sessions/{sid}/scorecard").raise_for_status().json()
    all_notes = client.get(url, params={"limit": 50}).raise_for_status().json()
    assert all_notes == {"items": score["handoff_notes"], "next_cursor": None, "total": 10}
    assert client.get(url, params={"category": "concern"}).json() == {"items": [], "total": 0, "next_cursor": None}


def test_invalid_limits_scopes_and_stored_anchor_do_not_echo_private_text(client):
    sid, other = create_session(client), create_session(client)
    url = f"/api/sessions/{sid}/handoff-notes"
    with store.connection(write=True) as db:
        insert(db, sid, 1)
        insert(db, sid, 2)
    token = client.get(url, params={"limit": 1}).json()["next_cursor"]
    assert token
    for route, params in [
        (f"/api/sessions/{other}/handoff-notes", {"cursor": token}), (url, {"cursor": token, "category": "concern"}),
        (url, {"cursor": "private malformed position"}), (url, {"cursor": token + "="}), (url, {"cursor": "x" * 257}),
        (url, {"limit": 0}), (url, {"limit": 51}), (url, {"category": "private-invalid-category"}),
    ]:
        response = client.get(route, params=params)
        assert response.status_code == 422
        assert token not in response.text and "private" not in response.text and "@example.test" not in response.text
    with store.connection(write=True) as db:
        db.execute("UPDATE session_handoff_notes SET created_at='private-invalid-stamp' WHERE id=?", (key(2),))
    error = client.get(url, params={"limit": 1})
    assert error.status_code == 409 and "private" not in error.text and "@example.test" not in error.text


def test_large_notes_project_payloads_for_the_visible_page_only(client, monkeypatch):
    sid = create_session(client)
    url = f"/api/sessions/{sid}/handoff-notes"
    payload = "Note-Payload/" + "x" * 1980
    author = "Note-Author/" + "operator" * 48
    with store.connection(write=True) as db:
        for i in range(1, 1101):
            insert(db, sid, i, body=payload, author=author)
    delivered = []
    connection = store.connection

    @contextmanager
    def observed(*args, **kwargs):
        def decode(value):
            if value.startswith(b"Note-Payload/"):
                delivered.append("body")
            if value.startswith(b"Note-Author/"):
                delivered.append("author")
            return value.decode("utf-8")

        with connection(*args, **kwargs) as db:
            db.text_factory = decode
            yield db

    monkeypatch.setattr(store, "connection", observed)
    page = client.get(url).raise_for_status().json()
    assert page["total"] == 1100 and page["next_cursor"]
    assert [n["id"] for n in page["items"]] == [key(i) for i in range(1100, 1080, -1)]
    assert delivered.count("body") == delivered.count("author") == 20
    delivered.clear()
    second = client.get(url, params={"limit": 1, "cursor": page["next_cursor"]}).raise_for_status().json()
    assert second["items"][0]["id"] == key(1080) and second["total"] == 1100
    assert sorted(delivered) == ["author", "body"]


def test_thin_get_save_conflict_and_noop_never_read_note_storage(client, monkeypatch):
    sid = create_session(client)
    score = f"/api/sessions/{sid}/scorecard"
    notes = f"/api/sessions/{sid}/handoff-notes"
    thin = {"include_handoff_notes": "false"}
    note = client.post(notes, json={"category": "observation", "body": "Private note"}).raise_for_status().json()
    full = client.get(score).raise_for_status().json()
    assert full["handoff_notes"] == [note] and "handoff_notes_paged" not in full
    assert client.get(score, params={"include_handoff_notes": True}).json() == full
    client.post(notes, json={"category": "follow_up", "body": "Second private note"}).raise_for_status()
    original = store.connection

    @contextmanager
    def no_note_reads(*args, **kwargs):
        def deny(action, table, column, *_):
            if action == sqlite3.SQLITE_READ and table == "session_handoff_notes":
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK

        with original(*args, **kwargs) as db:
            db.set_authorizer(deny)
            yield db

    with monkeypatch.context() as context:
        context.setattr(store, "connection", no_note_reads)
        assert client.get(score, params=thin).raise_for_status().json() == {**full, "handoff_notes": [], "handoff_notes_paged": True}
        grades = [{"criterion_id": "c", "criterion_label": "Criterion", "weight": 1, "rating": 4, "rationale": "Fixture"}]
        payload = {"items": grades, "expected_version": full["version"]}
        saved = client.put(score, params=thin, json=payload).raise_for_status().json()
        assert saved["handoff_notes"] == [] and saved["handoff_notes_paged"] is True
        assert saved["version"] != full["version"]
        assert client.put(score, params=thin, json=payload).status_code == 409
        assert client.put(score, params=thin, json={**payload, "expected_version": saved["version"]}).json() == saved
    legacy = client.put(score, json={"items": grades, "expected_version": saved["version"]}).raise_for_status().json()
    assert "handoff_notes_paged" not in legacy and len(legacy["handoff_notes"]) == 2 and legacy["version"] == saved["version"]


def test_missing_table_reads_are_empty_and_trash_remains_inaccessible(client):
    sid = create_session(client)
    url = f"/api/sessions/{sid}/handoff-notes"
    with store.connection(write=True) as db:
        db.execute("DROP TABLE session_handoff_notes")
    assert client.get(url).raise_for_status().json() == {"items": [], "total": 0, "next_cursor": None}
    assert client.get(f"/api/sessions/{sid}/scorecard").raise_for_status().json()["handoff_notes"] == []
    with store.connection() as db:
        assert db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_handoff_notes'").fetchone() is None
    client.post(f"/api/sessions/{sid}/trash").raise_for_status()
    assert client.get(url).status_code == 404
    assert client.get(f"/api/sessions/{uuid4()}/handoff-notes").status_code == 404
