"""Exercise retention upgrade on the two disposable CI images used by image-smoke.sh."""
from contextlib import closing
import hashlib
import json
import os
import secrets
import sqlite3
import sys

import httpx

REVIEW = "/data/review.sqlite3"


def read_database(name):
    return closing(sqlite3.connect(f"file:/data/{name}.sqlite3?mode=ro", uri=True))


def receipt(db, sid):
    row = db.execute("SELECT anonymized_at, anonymized_by FROM session_anonymizations WHERE session_id=?", (sid,)).fetchone()
    assert row is not None
    return list(row)


def history_digest(db, aid):
    rows = db.execute("""SELECT CAST(snapshot AS BLOB) FROM answer_history
                         WHERE answer_id=? AND revision=1 AND kind='baseline' AND actor IS NULL AND saved_at IS NULL""",
                      (aid,)).fetchall()
    assert len(rows) == 1
    return hashlib.sha256(rows[0][0]).hexdigest()


def prepare(web, control):
    from api import answer_history, store
    from api.retention_anonymizer import SessionAnonymizer

    example = web.get("/api/sessions/" + control).raise_for_status().json()
    answer, = example["answers"]
    assert example["candidate"] == "Upgrade fixture" and example["role"] == "Engineer"
    assert answer["revision"] == 1 and answer["answer"]
    fixture = {"control": control, "answer_sha256": hashlib.sha256(answer["answer"].encode()).hexdigest()}
    for kind in ("clean", "held"):
        interview = web.post("/api/sessions", json={k: example[k] for k in ("candidate", "role", "policy", "consent")})
        sid = interview.raise_for_status().json()["id"]
        created = web.post(f"/api/sessions/{sid}/answers", json={k: answer[k] for k in ("question", "answer", "references")})
        saved = created.raise_for_status().json()
        fixture[kind] = {"sid": sid, "aid": saved["id"]}

    with store.connection(write=True) as db:
        for kind in ("clean", "held"):
            entry = fixture[kind]
            SessionAnonymizer(db, entry["sid"]).run(preserve_scorecard_aggregates=False,
                                                   actor_email="fixture@ci.invalid", now_iso=store.timestamp())
            entry["receipt"] = receipt(db, entry["sid"])
        # Reproduce the stored shape an older writer could leave behind. The
        # reference row comes from the synthetic control and carries no real data.
        raw = json.dumps(answer_history.snapshot(answer), ensure_ascii=False, indent=2) + "\n"
        held = fixture["held"]
        db.execute("""INSERT INTO answer_history(answer_id,revision,kind,saved_at,actor,snapshot)
                      VALUES (?,1,'baseline',NULL,NULL,?)""", (held["aid"], raw))
        fixture["history_sha256"] = history_digest(db, held["aid"])
        assert fixture["history_sha256"] == hashlib.sha256(raw.encode("utf-8")).hexdigest()
        # Once main also installs visibility triggers, make startup discover this
        # fixture from its receipt and bytes instead of inheriting a computed hold.
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='retention_read_holds'").fetchone():
            db.execute("DELETE FROM retention_read_holds WHERE session_id=?", (held["sid"],))
    return fixture


def verify(web, fixture):
    clean, held, control = fixture["clean"], fixture["held"], fixture["control"]
    for name in ("review", "access"):
        with read_database(name) as db:
            assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",), name
    with read_database("review") as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone() == (3,)
        assert db.execute("SELECT count(*) FROM answers").fetchone() == (3,)
        assert db.execute("SELECT session_id FROM retention_read_holds").fetchall() == [(held["sid"],)]
        for entry in (clean, held):
            assert receipt(db, entry["sid"]) == entry["receipt"]
            assert db.execute("""SELECT 1 FROM answers a JOIN sessions s ON s.id=a.session_id
                                 WHERE s.id=? AND a.id=?""", (entry["sid"], entry["aid"])).fetchone()
        assert history_digest(db, held["aid"]) == fixture["history_sha256"]

    # The production configuration requires a real account. Its Secure cookie
    # is carried explicitly on these requests to the in-container HTTP listener.
    from api.access import COOKIE
    signup = web.post("/api/integrations/access/signup", json={
        "email": os.environ["INTERVIEWCHECK_OPERATOR_EMAIL"], "password": secrets.token_urlsafe(24),
        "inviteCode": os.environ["INTERVIEWCHECK_SIGNUP_SECRET"], "adminSecret": os.environ["ADMIN_BOOTSTRAP_SECRET"],
    }).raise_for_status()
    web.headers["Cookie"] = f"{COOKIE}={signup.cookies[COOKIE]}"
    ids = {entry["id"] for entry in web.get("/api/sessions").raise_for_status().json()}
    assert ids == {control, clean["sid"]}
    normal = web.get("/api/sessions/" + control).raise_for_status().json()
    original_answer = normal["answers"][0]["answer"]
    assert normal["candidate"] == "Upgrade fixture" and hashlib.sha256(original_answer.encode()).hexdigest() == fixture["answer_sha256"]
    erased = web.get("/api/sessions/" + clean["sid"]).raise_for_status().json()
    from api.retention_anonymizer import REDACTED_TEXT
    assert erased["privacy_state"] == "anonymized" and erased["answers"][0]["answer"] == REDACTED_TEXT
    for suffix in ("", f"/answers/{held['aid']}/history"):
        rejected = web.get(f"/api/sessions/{held['sid']}{suffix}")
        assert rejected.status_code == 409 and rejected.headers.get("X-InterviewCheck-Conflict") == "interview-privacy"
        assert original_answer not in rejected.text


if __name__ == "__main__":
    assert os.environ["INTERVIEWCHECK_DB"] == REVIEW and os.environ["INTERVIEWCHECK_ACCESS_DB"] == "/data/access.sqlite3"
    origin = "http://127.0.0.1:8000"
    with httpx.Client(base_url=origin, headers={"X-InterviewCheck": "1", "Origin": origin}, trust_env=False) as client:
        if sys.argv[1] == "prepare":
            print(json.dumps(prepare(client, sys.argv[2]), separators=(",", ":")))
        elif sys.argv[1] == "verify":
            verify(client, json.loads(sys.argv[2]))
            print("Normal and erased controls are readable. Conflicting history is withheld with its original receipt and bytes intact.")
        else:
            raise SystemExit("Expected prepare or verify.")
