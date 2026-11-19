from uuid import uuid4
import pytest
from fastapi.testclient import TestClient

from api import store
from api.main import app


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "catalog.sqlite"))
    for name in ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(name, raising=False)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        yield web


def session(web, name, role="Engineer"):
    res = web.post(
        "/api/sessions", json={"candidate": name, "role": role, "consent": True, "policy": "HiddenPolicy"}
    )
    res.raise_for_status()
    return res.json()["id"]


def lookup(client, q, **options):
    result = client.post("/api/search", json={"query": q, **options})
    result.raise_for_status()
    return result.json()


def test_search_rank_literal_dedup_and_sensitive_field_exclusions(client):
    rid = client.post(
        "/api/roles",
        json={
            "name": "Straße_100%",
            "description": "NotIndexedMarker",
            "questions": ["NotIndexedMarker"],
            "policy": "NotIndexedMarker",
        },
    ).json()["id"]
    sid = session(client, "Straße_100% Example", "Straße_100% role")
    answer = client.post(
        f"/api/sessions/{sid}/answers",
        json={
            "question": "What happened on the Straße_100% site?",
            "answer": "X" * 8000 + " StraßE_100% appeared next to the tachometer.",
            "references": [{"label": "NotIndexedMarker", "text": "NotIndexedMarker"}],
        },
    ).json()
    client.patch(
        f"/api/sessions/{sid}/answers/{answer['id']}",
        json={"note": "NotIndexedMarker", "disposition": "unresolved"},
    ).raise_for_status()
    result = lookup(client, "STRASSE_100%")
    assert [(r["kind"], r["id"], r["field"]) for r in result["items"]] == [
        ("role", rid, "role_name"),
        ("session", sid, "candidate"),
        ("answer", answer["id"], "question"),
    ]
    assert not lookup(client, "NotIndexedMarker")["items"]
    assert not lookup(client, "HiddenPolicy")["items"]
    assert not lookup(client, "' OR TRUE;--")["items"]
    assert lookup(client, "_100%", limit=2)["has_more"]
    assert lookup(client, "%", kinds=["session"])["items"][0]["session_id"] == sid
    (hit,) = lookup(client, "tachometer")["items"]
    assert hit["field"] == "answer" and "tachometer" in hit["snippet"] and len(hit["snippet"]) <= 182
    assert lookup(client, "", kinds=["session"]) == {"items": [], "has_more": False}
    assert client.get("/api/roles/" + rid).json()["name"] == "Straße_100%"


def test_feed_pages_filters_ties_counts_and_trash(client):
    ids = [session(client, "Case_" + str(i)) for i in range(9)]
    exact = "The fan drive oscillates when the third bearing contacts the outer housing."
    for sid in ids[:2]:
        client.post(
            f"/api/sessions/{sid}/answers",
            json={
                "question": "What failed?",
                "answer": exact,
                "references": [{"label": "ref", "text": exact}],
            },
        ).raise_for_status()
    client.post(f"/api/sessions/{ids[1]}/finish").raise_for_status()
    with store.connection(write=True) as db:
        db.execute("UPDATE sessions SET created_at='2026-01-01T12:00:00Z'")
        db.execute("INSERT INTO session_trash VALUES (?,?,?)", (ids[2], store.timestamp(), str(uuid4())))

    def feed(**params):
        r = client.get("/api/interviews/feed", params=params)
        r.raise_for_status()
        return r.json()

    first, second = feed(page_size=4), feed(page_size=4, page=2)
    assert first["total"] == first["filtered"] == 8 and first["pages"] == 2
    assert [s["id"] for s in first["items"] + second["items"]] == sorted(set(ids) - {ids[2]})
    assert not set(first["items"][0]).intersection({"policy", "permitted_sources", "legacy"})
    assert feed(review="pending", status="finished")["items"][0]["id"] == ids[1]
    assert feed(review="clear", status="active")["filtered"] == 6
    assert feed(page_size=4, page=99)["page"] == 2
    assert feed(q="Engineer cAsE_8")["filtered"] == 1
    assert not lookup(client, "Case_2")["items"]
    overview = client.get("/api/interviews/overview").json()
    assert (
        overview["total"],
        overview["active_count"],
        overview["pending_count"],
        overview["pending_sessions"],
    ) == (8, 7, 2, 2)
    assert len(overview["active"]) == 5 and len(overview["pending"]) == 2
    with store.connection(write=True) as db:
        db.execute("INSERT INTO session_trash VALUES (?,?,?)", (ids[0], store.timestamp(), str(uuid4())))
    assert not any(row["session_id"] == ids[0] for row in lookup(client, "oscillates")["items"])
    assert client.get("/api/interviews/overview").json()["pending_count"] == 1


def test_discovery_limits_and_account_gate(client, monkeypatch):
    assert client.post("/api/search", json={"query": "x" * 161}).status_code == 422
    assert client.post("/api/search", json={"query": "%", "limit": 51}).status_code == 422
    assert client.get("/api/interviews/feed?page_size=101").status_code == 422
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", "http://127.0.0.1:8787")
    assert client.get("/api/interviews/feed").status_code == 401
    assert client.get("/api/interviews/overview").status_code == 401
    assert client.post("/api/search", json={"query": "abc"}).status_code == 401


def test_search_rejects_fts_on_nul_and_control_characters(client):
    session(client, "Control Guard Candidate")
    for query in ("\x00ab", "\x00abc", "a\x00bc", "ab\x00c", "\x01abc", "\tabc"):
        resp = client.post("/api/search", json={"query": query})
        assert resp.status_code == 200, (query, resp.status_code, resp.text)
        assert resp.json() == {"items": [], "has_more": False}


def test_search_fts_matches_unicode_casefold_to_ascii_ligatures(client):
    cases = [
        ("O\ufb03ce_Hero", "office", "ce_hero"),
        ("O\ufb00er_Check", "offer", "fer_check"),
        ("\ufb01le_Parser", "file", "le_parser"),
        ("\ufb02ow_Meter", "flow", "ow_meter"),
        ("Ba\ufb04e_Wall", "baffle", "fle_wall"),
        ("\ufb05op_Valve", "stop", "op_valve"),
        ("\ufb06ep_Gate", "step", "ep_gate"),
        ("Te\u017fting_Run", "testing", "ting_run"),
        ("\u212aelvin_Probe", "kelvin", "vin_probe"),
    ]
    created = {candidate: session(client, candidate) for candidate, _, _ in cases}
    for candidate, primary, tail in cases:
        sid = created[candidate]
        hit = lookup(client, primary, kinds=["session"])["items"]
        assert [item["session_id"] for item in hit] == [sid]
        assert hit[0]["label"] == candidate
        tail_hit = lookup(client, tail, kinds=["session"])["items"]
        assert [item["session_id"] for item in tail_hit] == [sid]


def test_search_fts_migrates_legacy_triggers_for_ligatures(tmp_path, monkeypatch):
    import sqlite3
    from contextlib import closing
    from api import search_fts

    db_path = tmp_path / "legacy_fts.sqlite"
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(db_path))
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        sid = session(web, "O\ufb03ce_Legacy")
    # Simulate an earlier M9 database whose FTS triggers only folded sharp-s.
    with closing(sqlite3.connect(db_path)) as raw, raw:
        raw.execute("DROP TRIGGER fts_roles_ai")
        raw.execute(
            "CREATE TRIGGER fts_roles_ai AFTER INSERT ON roles BEGIN "
            "INSERT INTO fts_roles(rowid, name) VALUES (new.rowid, replace(new.name, 'ß', 'ss')); END"
        )
        raw.execute("DELETE FROM fts_sessions")
    store.initialize(db_path)
    with closing(sqlite3.connect(db_path)) as raw:
        assert search_fts._triggers_current(raw)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as web:
        hits = lookup(web, "office", kinds=["session"])["items"]
        assert [item["session_id"] for item in hits] == [sid]


