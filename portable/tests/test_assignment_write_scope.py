"""A triage write must retain its active-session check until it commits."""
from contextlib import closing, contextmanager
import sqlite3
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from api import main, store


@pytest.mark.parametrize("bulk", [False, True])
def test_assignment_cannot_be_interleaved_with_move_to_trash(tmp_path, monkeypatch, bulk):
    path = tmp_path / "work.sqlite"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(path))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "access.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_PUBLIC_ORIGIN", "INTERVIEWCHECK_ACCESS_URL"):
        monkeypatch.delenv(key, raising=False)
    with TestClient(main.app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        session = {"candidate": "Fixture", "role": "Tester", "policy": "Manual allowed", "consent": True}
        sid = client.post("/api/sessions", json=session).raise_for_status().json()["id"]
        original = store.connection
        observed = []

        @contextmanager
        def compete(*args, **kwargs):
            with original(*args, **kwargs) as db:
                if kwargs.get("write"):
                    def during_assignment(statement):
                        if not statement.startswith("INSERT INTO session_assignments"):
                            return
                        with closing(sqlite3.connect(path, timeout=0)) as second:
                            try:
                                second.execute("BEGIN IMMEDIATE")
                            except sqlite3.OperationalError as exc:
                                observed.append(str(exc))
                            else:
                                # A real second writer moves the previously eligible session.
                                second.execute("INSERT INTO session_trash VALUES (?,?,?)", (sid, store.timestamp(), str(uuid4())))
                                second.commit()
                                observed.append("moved to Trash")
                    db.set_trace_callback(during_assignment)
                yield db

        monkeypatch.setattr(store, "connection", compete)
        body = {"assignee_email": "reviewer@example.test"}
        if bulk:
            saved = client.post("/api/interviews/assignments/bulk", json={**body, "session_ids": [sid]})
        else:
            saved = client.put(f"/api/sessions/{sid}/assignment", json=body)
        saved.raise_for_status()
        assert len(observed) == 1 and "locked" in observed[0], observed
        assert client.get(f"/api/sessions/{sid}/assignment").raise_for_status().json()["assignment"]["assignee_email"] == body["assignee_email"]
