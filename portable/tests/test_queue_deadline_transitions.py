from datetime import datetime, timedelta, timezone

from api import assignment_queue, session_assignment, store
from backup_requests import client, create_session


NOW = datetime(2026, 11, 21, 12, tzinfo=timezone.utc)
WINDOW_MS = 48 * 60 * 60 * 1000
QUEUE = "/api/interviews/assignments"


def put_deadline(db, sid, value):
    db.execute("""INSERT INTO session_assignments(session_id,assignee_email,assigned_by,priority,due_at,updated_at)
                  VALUES(?,'reviewer@example.test','local-operator','normal',?,?)
                  ON CONFLICT(session_id) DO UPDATE SET due_at=excluded.due_at""", (sid, value, NOW.isoformat()))


def fixed_clock(monkeypatch):
    class FixedTime(datetime):
        @classmethod
        def now(cls, tz=None):
            return NOW.astimezone(tz) if tz else NOW.replace(tzinfo=None)

    monkeypatch.setattr(session_assignment, "datetime", FixedTime)


def test_hint_is_first_whole_millisecond_at_or_after_each_transition(client):
    sid = create_session(client)
    cases = [
        # (stored timestamp, overdue, soon, milliseconds to next change)
        (None, 0, 0, None), ("invalid", 0, 0, None),
        ("2026-11-21T11:59:59.999999Z", 1, 0, None),
        ("2026-11-21T13:00:00+01:00", 0, 1, 1),
        ("2026-11-21T12:00:00.000999", 0, 1, 1),
        ("2026-11-21T12:00:00.001000Z", 0, 1, 2),
        ("2026-11-23T04:00:00-08:00", 0, 1, WINDOW_MS + 1),
        ("2026-11-23T12:00:00.000001Z", 0, 0, 1),
        ("2026-11-23T12:00:00.002000Z", 0, 0, 2),
        ("2026-11-23T12:00:00.002001Z", 0, 0, 3),
    ]
    kwargs = dict(viewer="local-operator", assignee="", priority="", due="", limit=1, page=1,
                  has_assignments=True, now=NOW, include_transition=True)
    with store.connection(write=True) as db:
        for stamp, overdue, soon, hint in cases:
            put_deadline(db, sid, stamp)
            response = assignment_queue.read_page(db, **kwargs)
            assert response["due_counts"] == {"overdue": overdue, "due_soon": soon}, stamp
            assert response["next_transition_ms"] == hint, stamp
            if hint is not None:
                advanced = assignment_queue.read_page(db, **{**kwargs, "now": NOW + timedelta(milliseconds=hint)})
                assert advanced["due_counts"] != response["due_counts"]
                previous = assignment_queue.read_page(db, **{**kwargs, "now": NOW + timedelta(milliseconds=hint - 1)})
                assert previous["due_counts"] == response["due_counts"]
        distant = datetime.max.replace(tzinfo=timezone.utc)
        put_deadline(db, sid, distant.isoformat())
        response = assignment_queue.read_page(db, **kwargs)
        until_soon = distant - NOW - timedelta(hours=48)
        assert response["next_transition_ms"] == (until_soon // timedelta(microseconds=1) + 999) // 1000
        assert 2**31 < response["next_transition_ms"] < 2**53


def test_hint_is_global_in_one_totals_scan_and_does_not_change_the_legacy_response(client, monkeypatch):
    fixed_clock(monkeypatch)
    visible, near, trashed = (create_session(client) for _ in range(3))
    with store.connection(write=True) as db:
        put_deadline(db, near, (NOW + timedelta(hours=48, milliseconds=7)).isoformat())
        put_deadline(db, trashed, NOW.isoformat())
    client.post(f"/api/sessions/{trashed}/trash").raise_for_status()
    filters = {"assignee": "unassigned", "limit": 1, "page": 10}
    original = client.get(QUEUE, params=filters).raise_for_status().json()
    explicit_false = client.get(QUEUE, params={**filters, "include_transition": "false"}).raise_for_status().json()
    assert original == explicit_false and "next_transition_ms" not in original
    assert [r["session_id"] for r in original["items"]] == [visible]
    assert original["due_counts"] == {"overdue": 0, "due_soon": 0}

    # No page needs deadline filtering here. Each active row is parsed exactly
    # once for the totals and hint combined, including the off-page assignment.
    parsed = []
    due_us = assignment_queue._due_microseconds

    def observe(value, now):
        parsed.append(value)
        return due_us(value, now)

    monkeypatch.setattr(assignment_queue, "_due_microseconds", observe)
    page = client.get(QUEUE, params={**filters, "include_transition": "true"}).raise_for_status().json()
    assert page.pop("next_transition_ms") == 7 and page == original
    assert len(parsed) == 2 and NOW.isoformat() not in parsed
    both = client.get(QUEUE, params={**filters, "include_transition": True, "include_versions": True}).json()
    assert both["next_transition_ms"] == 7
    assert "assignment_version" in both["items"][0]


def test_missing_assignment_table_returns_null_without_creating_storage(client):
    create_session(client)
    with store.connection(write=True) as db:
        db.execute("DROP TABLE session_assignments")
    response = client.get(QUEUE, params={"include_transition": "true", "due": "soon"}).raise_for_status().json()
    assert response["next_transition_ms"] is None
    assert response["filtered"] == 0 and response["counts"]["unassigned"] == 1
    with store.connection() as db:
        assert not db.execute("SELECT 1 FROM sqlite_master WHERE name='session_assignments'").fetchone()
