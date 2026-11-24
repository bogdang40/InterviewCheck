from collections import Counter
from datetime import datetime, timedelta, timezone
from uuid import UUID

from api import assignment_queue, store
from backup_requests import client, create_session


NOW = datetime(2026, 11, 21, 12, tzinfo=timezone.utc)


def read(db, **options):
    filters = dict(viewer="operator", assignee="", priority="", due="", limit=2, page=1,
                   has_assignments=True, now=NOW, include_transition=True)
    return assignment_queue.read_page(db, **{**filters, **options})


def test_equivalent_deadlines_use_update_then_id_across_page_boundaries(client):
    ids = [create_session(client) for _ in range(8)]
    ordered_tie = sorted(ids[2:4])
    entries = [
        # Lexically earlier, but one microsecond LATER in UTC than the following three rows.
        (ids[0], "normal", "2026-11-21T05:30:00.123457-05:00", "2026-11-22"),
        (ids[1], "normal", "2026-11-21T14:30:00.123456+04:00", "2026-11-21"),
        (ids[2], "normal", "2026-11-21T10:30:00.123456Z", "2026-11-20"),
        (ids[3], "normal", "2026-11-21T10:30:00.123456", "2026-11-20"),
        (ids[4], "normal", "2026-11-21T13:00:00Z", "2026-11-20"),
        (ids[5], "normal", "000-invalid", "2026-11-19"),
        (ids[6], "normal", None, "2026-11-20"),
        (ids[7], "high", "2027-01-01T00:00:00Z", "2026-11-21"),
    ]
    with store.connection(write=True) as db:
        db.executemany("""INSERT INTO session_assignments(session_id,priority,due_at,updated_at,assignee_email,assigned_by)
                          VALUES(?,?,?,?,'qa@example.test','operator')""", entries)
        pages = [read(db, page=n) for n in range(1, 5)]
        rows = [row for page in pages for row in page["items"]]
        assert [r["session_id"] for r in rows] == [ids[7], ids[1], *ordered_tie, ids[0], ids[4], ids[6], ids[5]]
        assert {r["session_id"]: r["due_at"] for r in rows} == {sid: due for sid, _, due, _ in entries}
        for page in pages:
            assert page["due_counts"] == {"overdue": 4, "due_soon": 1}
            assert page["next_transition_ms"] == 3_600_001
        overdue = [row["session_id"] for n in (1, 2) for row in read(db, due="overdue", page=n)["items"]]
        assert overdue == [ids[1], *ordered_tie, ids[0]]


def test_queue_parses_only_eligible_deadlines_for_sorting(client, monkeypatch):
    ids = [str(UUID(int=i + 1)) for i in range(256)]
    stamps = [(NOW + timedelta(hours=1, microseconds=i)).isoformat() for i in range(240)]
    with store.connection(write=True) as db:
        db.executemany("""INSERT INTO sessions(id,candidate,role,policy,consent,created_at)
                          VALUES(?,'Fixture','Engineer','Manual',1,?)""", ((sid, NOW.isoformat()) for sid in ids))
        db.executemany("""INSERT INTO session_assignments(session_id,priority,due_at,updated_at,assignee_email,assigned_by)
                          VALUES(?,?,?,?,'qa@example.test','operator')""", (
            (sid, "high" if i < 3 else "normal", stamps[i], NOW.isoformat()) for i, sid in enumerate(ids[:240])
        ))
    parsed = Counter()
    parse = assignment_queue._due_microseconds

    def observe(raw, now):
        parsed[raw] += 1
        return parse(raw, now)

    monkeypatch.setattr(assignment_queue, "_due_microseconds", observe)
    totals_scan = Counter([*stamps, *([None] * 16)])
    for filters, expected in [
        ({"priority": "high", "due": "soon"}, stamps[:3]),
        ({"assignee": "unassigned"}, []),
        ({}, stamps),
    ]:
        parsed.clear()
        # Each queue request opens its own read connection after the indexed inserts commit.
        with store.connection() as db:
            result = read(db, **filters)
        assert len(result["items"]) == 2
        assert result["due_counts"] == {"overdue": 0, "due_soon": 240}
        assert parsed == totals_scan + Counter(expected)
