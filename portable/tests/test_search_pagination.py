import base64
from contextlib import contextmanager
import sqlite3
from uuid import UUID

import pytest
from fastapi.testclient import TestClient

from api import search_fts, store
from api.main import app


def uid(number):
    return str(UUID(int=number))


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "search.sqlite"))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(tmp_path / "accounts.sqlite"))
    for name in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(name, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


@pytest.fixture(params=["fallback", "fts"])
def populated(client, request, monkeypatch):
    if request.param == "fts":
        with store.connection() as db:
            if not search_fts.has_fts(db):
                pytest.skip("SQLite trigram FTS unavailable")
    else:
        monkeypatch.setattr(search_fts, "has_fts", lambda db: False)
    client.post("/api/roles", json={"id": uid(1), "name": "Quorum"}).raise_for_status()
    for number, name, role in [(1, "Quorum", "Quorum engineer"), (2, "A quorum", "Quorum"), (3, "Quorum in Trash", "Engineer")]:
        client.post("/api/sessions", json={"id": uid(number), "candidate": name, "role": role, "role_id": None,
                                           "policy": "Private policy fixture", "consent": True}).raise_for_status()
    rows = [(uid(i), uid(1), "Quorum", "Also a quorum") for i in [1, *range(10, 70)]]
    rows += [
        (uid(70), uid(2), "A quorum?", "Quorum"), (uid(71), uid(2), "Quorum prefix", "Quorum"),
        (uid(72), uid(2), "Body question", "X" * 250 + " quorum body " + "Y" * 240),
        (uid(73), uid(2), "Body question", "Quorum prefix"), (uid(74), uid(2), "Body question", "Quorum"),
        (uid(75), uid(3), "Quorum", "Quorum"),
    ]
    with store.connection(write=True) as db:
        db.executemany(
            """INSERT INTO answers(id,session_id,question,answer,refs,result,status,note)
               VALUES(?,?,?,?,'[]','{}','no_match','Private note fixture')""", rows,
        )
    client.post(f"/api/sessions/{uid(3)}/trash").raise_for_status()
    return client


def lookup(client, **options):
    return client.post("/api/search", json=options).raise_for_status().json()


def test_pages_preserve_global_rank_and_best_field_across_boundaries(populated):
    client = populated
    expected = [("role", uid(1), "role_name"), ("session", uid(1), "candidate"), ("session", uid(2), "role")]
    expected += [("answer", uid(i), "question") for i in [1, *range(10, 70), 71, 70]]
    expected += [("answer", uid(i), "answer") for i in (74, 73, 72)]
    legacy = lookup(client, query="Quorum", limit=50)
    assert set(legacy) == {"items", "has_more"} and legacy["has_more"]
    assert all(set(hit) == {"kind", "id", "session_id", "field", "label", "snippet"} for hit in legacy["items"])
    cursor, hits = "", []
    for index in range(len(expected) + 1):
        page = lookup(client, query="QUORUM" if index % 2 else "Quorum", limit=7 if index % 2 else 1,
                      kinds=["answer", "role", "session"] if index % 2 else ["role", "session", "answer"], cursor=cursor)
        hits.extend(page["items"])
        assert all(len(h["snippet"]) <= 182 for h in page["items"])
        if not page["has_more"]:
            assert page["next_cursor"] is None
            break
        assert page["items"] and page["next_cursor"] != cursor
        cursor = page["next_cursor"]
    assert [(h["kind"], h["id"], h["field"]) for h in hits] == expected
    assert all(("role" in h) == (h["kind"] != "role") for h in hits)
    assert all(("created_at" in h) == (h["kind"] != "role") for h in hits)
    assert hits[1]["role"] == "Quorum engineer" and hits[-1]["role"] == "Quorum"
    assert hits[-1]["snippet"].startswith("…") and hits[-1]["snippet"].endswith("…")
    assert hits[1]["created_at"] == client.get(f"/api/sessions/{uid(1)}").json()["created_at"]


def test_cursor_binding_and_terminal_shapes(populated):
    client = populated
    assert lookup(client, query="") == {"items": [], "has_more": False}
    assert lookup(client, query="", cursor="") == {"items": [], "has_more": False, "next_cursor": None}
    args = {"query": "quorum", "kinds": ["answer", "role"], "limit": 2}
    token = lookup(client, **args, cursor="")["next_cursor"]
    decoded = base64.urlsafe_b64decode(token + "==")
    assert b"quorum" not in decoded.lower()
    assert lookup(client, **{**args, "query": "QuOrUm", "kinds": ["role", "answer", "answer"]}, cursor=token)["items"]
    changed_version = base64.urlsafe_b64encode(bytes([255]) + decoded[1:]).decode().rstrip("=")
    for changed in ({"kinds": ["role"]}, {"query": "private unrelated term"}, {"cursor": changed_version},
                    {"cursor": " "}, {"cursor": "broken"}, {"cursor": token + "="}, {"cursor": "x" * 129}, {"cursor": None}):
        response = client.post("/api/search", json={**args, "cursor": token, **changed})
        assert response.status_code == 422
        assert "private unrelated term" not in response.text and token not in response.text


def test_scoped_pages_do_not_read_unrequested_columns(populated, monkeypatch):
    client = populated
    reads = set()
    connection = store.connection

    @contextmanager
    def observed(*args, **kwargs):
        with connection(*args, **kwargs) as db:
            def authorize(action, table, column, *_):
                if action == sqlite3.SQLITE_READ:
                    reads.add((table, column))
                return sqlite3.SQLITE_OK
            db.set_authorizer(authorize)
            yield db

    monkeypatch.setattr(store, "connection", observed)
    for opts in ({}, {"cursor": ""}):
        reads.clear()
        assert lookup(client, query="quorum", kinds=["session"], **opts)["items"]
        assert not any(t in {"roles", "answers", "session_context"} or t.startswith("fts_answers") for t, _ in reads)
        assert not any(col in {"policy", "legacy", "permitted_sources"} for _, col in reads)
        reads.clear()
        assert lookup(client, query="quorum", kinds=["role"], **opts)["items"]
        assert not any(t in {"answers", "sessions", "session_trash"} or t.startswith(("fts_answers", "fts_sessions")) for t, _ in reads)
        reads.clear()
        # A full page of title hits must not read answer bodies to check for later matches.
        assert lookup(client, query="quorum", kinds=["answer"], limit=5, **opts)["items"]
        assert not ({("answers", c) for c in ("answer", "refs", "note", "result", "legacy")} & reads)


def test_unindexed_unicode_paging_and_trashed_anchor(client):
    args = {"query": "ß", "kinds": ["session"], "limit": 1}
    for i, title in enumerate(("SS", "ßx", "Maße"), start=1):
        client.post("/api/sessions", json={"id": uid(i), "candidate": title, "role": "Engineer",
                                           "consent": True, "policy": "Manual"}).raise_for_status()
    run = lookup(client, **args, cursor="")
    assert run["items"][0]["id"] == uid(1)
    client.post(f"/api/sessions/{uid(1)}/trash").raise_for_status()
    second = lookup(client, **{**args, "query": "ss", "limit": 2}, cursor=run["next_cursor"])
    assert [h["id"] for h in second["items"]] == [uid(2), uid(3)]
    assert not second["has_more"] and second["next_cursor"] is None
