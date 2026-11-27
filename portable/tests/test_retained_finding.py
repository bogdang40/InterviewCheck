"""The local visibility check and v6 reader recognize only retention-produced finding text."""
from contextlib import closing
from copy import deepcopy
from hashlib import sha256
import json
import sqlite3

import pytest

from api import retained_finding, store
from api.evidence import compare
from api.migrate import ARCHIVED
from api.models import Reference
from api.retention_anonymizer import REDACTED_TEXT, SessionAnonymizer
from backup_requests import client, create_session, preview, restore

PRIVATE = "Private original candidate wording"
PASSAGE = "Copper bearings isolate thermal stress during coastal turbine operation."
REFERENCE = Reference(label="Reference", text=PASSAGE, permitted=False)


def sql_allows(raw):
    # The runtime uses this predicate only after json_valid succeeds.
    with closing(sqlite3.connect(":memory:")) as db:
        conflict, = db.execute(
            f"WITH sample(result) AS (VALUES(:doc)) SELECT {retained_finding.UNSAFE_TEXT_SQL} FROM sample r",
            {**retained_finding.TEXT_PARAMS, "doc": raw},
        ).fetchone()
    return conflict == 0


@pytest.mark.parametrize(("question", "answer", "refs", "status"), [
    ("How?", "Yes", [], "insufficient"),
    ("How?", "Check thermal expansion.", [], "insufficient"),
    ("How?", PASSAGE, [], "insufficient"),
    ("How?", "yes yes yes yes yes yes yes", [], "insufficient"),
    ("How?", "I wrote six independent logs for the database.", [REFERENCE], "no_match"),
    ("How?", "yes yes yes yes yes yes yes", [REFERENCE], "no_match"),
    ("How?", PASSAGE, [REFERENCE], "match"),
])
def test_original_scrubber_leaves_known_text_for_older_statuses(question, answer, refs, status):
    finding = compare(question, answer, refs)
    assert finding["status"] == status
    # The original retention writer preserved the explanation and replaced a quoted probe.
    if "You said" in finding["follow_up"]:
        finding["follow_up"] = REDACTED_TEXT
    for p in finding["passages"]:
        p["answer_excerpt"] = REDACTED_TEXT
    assert retained_finding.recognized_text(finding["explanation"], finding["follow_up"])
    assert sql_allows(json.dumps(finding))


def test_both_recomputed_probes_and_the_original_native_pair_are_recognized():
    quoted = compare("How?", REDACTED_TEXT, [])
    generic = compare("Describe 'Redacted by retention policy'.", REDACTED_TEXT, [])
    assert quoted["follow_up"] != generic["follow_up"]
    for finding in (quoted, generic, ARCHIVED):
        assert retained_finding.recognized_text(finding["explanation"], finding["follow_up"])
        for ascii_only in (True, False):
            assert sql_allows(json.dumps(finding, ensure_ascii=ascii_only))


def test_sql_rejects_private_or_ambiguous_free_text_without_relying_on_a_phrase_prefix():
    base = compare("How?", REDACTED_TEXT, [])
    for field in ("explanation", "follow_up"):
        for bad in (PRIVATE, "", base[field] + " " + PRIVATE, PRIVATE + " " + base[field], base[field] + "\x00" + PRIVATE):
            invalid = {**base, field: bad}
            assert not retained_finding.recognized_text(invalid["explanation"], invalid["follow_up"])
            assert not sql_allows(json.dumps(invalid))
        assert not sql_allows(json.dumps({k: v for k, v in base.items() if k != field}))
        assert not sql_allows(json.dumps({**base, field: None}))
        duplicate = json.dumps(base)[:-1] + "," + json.dumps(field) + ":" + json.dumps(PRIVATE) + "}"
        assert not sql_allows(duplicate)


def archive(client, question="How?"):
    sid = create_session(client)
    client.post(f"/api/sessions/{sid}/answers", json={"question": question, "answer": PASSAGE}).raise_for_status()
    with store.connection(write=True) as db:
        SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=True, actor_email="operator@example.test",
                                       now_iso=store.timestamp())
    return client.get("/api/backups/workspace", params={"session_id": sid}).raise_for_status().json()


@pytest.mark.parametrize("notice", [False, True])
def test_confirmed_archive_refuses_private_free_text_before_restore(client, tmp_path, monkeypatch, notice):
    document = archive(client)
    record, = document["sessions"]
    record["consent"] = notice
    assert record["privacy"]["state"] == "anonymized"
    target = tmp_path / "confirmed.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    for field in ("explanation", "follow_up"):
        for value in (PRIVATE, "Discuss the evidence. " + PRIVATE,
                      record["answers"][0]["result"][field] + PRIVATE):
            invalid = deepcopy(document)
            invalid["sessions"][0]["answers"][0]["result"][field] = value
            raw = json.dumps(invalid).encode()
            for response in (client.post("/api/backups/preview", content=raw),
                             client.post("/api/backups/restore", content=raw, headers={"X-Backup-Preview": sha256(raw).hexdigest()})):
                assert response.status_code == 422 and PRIVATE not in response.text
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM sessions").fetchone()[0] == 0
    # The historical scrubber replaced a quoted probe with the fixed marker.
    record["answers"][0]["result"]["follow_up"] = REDACTED_TEXT
    valid = json.dumps(document).encode()
    restore(client, valid, preview(client, valid)).raise_for_status()
    saved = client.get(f"/api/sessions/{record['id']}").raise_for_status().json()
    assert saved["answers"][0]["result"]["follow_up"] == REDACTED_TEXT and saved["privacy_state"] == "anonymized"


def test_ordinary_file_keeps_its_existing_follow_up_validation(client):
    sid = create_session(client)
    client.post(f"/api/sessions/{sid}/answers", json={"question": "How?", "answer": PASSAGE}).raise_for_status()
    doc = client.get("/api/backups/workspace").raise_for_status().json()
    row = doc["sessions"][0]
    assert row["privacy"]["state"] == "unmarked"
    row["answers"][0]["result"]["follow_up"] = "Which assumption would you test under load?"
    assert client.post("/api/backups/preview", json=doc).status_code == 200
