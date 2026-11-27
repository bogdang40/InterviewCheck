"""A selected question handoff discloses only current pending text in saved queue order."""
from contextlib import contextmanager
from hashlib import sha256
import sqlite3
from uuid import UUID, uuid4

import pytest

from api import deferred_items, store
from api.retention_anonymizer import SessionAnonymizer
from backup_requests import client, preview as backup_preview, restore
from test_deferred_questions import PARENT, action, child, get_item, prepare, receipt, select


def guard(row):
    return {"id": row["id"], "version": row["version"]}


def preview(client, base, picks):
    return client.post(base + "/deferred-questions/handoff/preview", json={"items": picks})


def verify(client, base, picks, digest):
    return client.post(base + "/deferred-questions/handoff/verify", json={"items": picks, "preview_sha256": digest})


def expected(text):
    return {"text": text, "sha256": sha256(text.encode("utf-8")).hexdigest()}


def ordered_item(client, base, parent, number, wording):
    return client.post(base + "/deferred-questions", json={"id": str(UUID(int=number)), "parent_answer_id": parent,
                       "question": wording, "expected_material": receipt(client, base, parent)}).raise_for_status().json()


def refused(response):
    assert response.status_code == 409 and response.headers["X-InterviewCheck-Conflict"] == "deferred-question"
    assert response.json() == {"detail": "Selected questions changed or are unavailable. Refresh the queue and preview again."}


def test_ordered_utf8_duplicate_wording_and_unselected_changes(client, monkeypatch):
    base, (first, second) = prepare(client)
    monkeypatch.setattr(store, "timestamp", lambda: "2026-11-03T00:00:00+00:00")
    earliest = ordered_item(client, base, second, 3, "Review café?\nExplain\twhy.")
    monkeypatch.setattr(store, "timestamp", lambda: "2026-11-04T00:00:00+00:00")
    b = ordered_item(client, base, first, 2, "Which 例?")
    a = ordered_item(client, base, first, 1, "Which 例?")
    excluded = ordered_item(client, base, second, 4, "Unselected private question?")
    picks = [guard(b), guard(a), guard(earliest)]
    wanted = expected("1. Review café?\nExplain\twhy.\n2. Which 例?\n3. Which 例?\n")
    result = preview(client, base, picks)
    assert result.raise_for_status().json() == wanted and result.headers["cache-control"] == "no-store"
    action(client, base, excluded, "dismiss").raise_for_status()
    client.patch(base + "/answers/" + first, json={"note": "Private review note.",
                 "disposition": "explained", "expected_revision": 1}).raise_for_status()
    assert verify(client, base, list(reversed(picks)), wanted["sha256"]).raise_for_status().json() == wanted
    refused(verify(client, base, picks, "0" * 64))
    client.post(base + "/finish").raise_for_status()
    assert preview(client, base, picks).raise_for_status().json() == wanted
    assert verify(client, base, picks, wanted["sha256"]).raise_for_status().json() == wanted


def test_fifty_maximum_questions_share_one_parent_read_in_each_read_only_snapshot(client, monkeypatch):
    base, (parent, _) = prepare(client)
    text = "🧭" * 4000
    proof = receipt(client, base, parent)
    picks = []
    for number in range(50):
        row = client.post(base + "/deferred-questions", json={"id": str(uuid4()), "parent_answer_id": parent,
                          "question": text, "expected_material": proof}).raise_for_status().json()
        picks.append(guard(row))
    wanted = expected("".join(f"{n}. {text}\n" for n in range(1, 51)))
    assert len(wanted["text"].encode()) == 800241

    real_connection = store.connection
    scans = []

    @contextmanager
    def query_only(*args, **kwargs):
        assert not kwargs.get("write")
        with real_connection(*args, **kwargs) as db:
            db.execute("PRAGMA query_only=ON")
            seen = []
            scans.append(seen)
            def read_row(cursor, values):
                row = sqlite3.Row(cursor, values)
                if {"id", "answer", "question", "refs", "result"} <= set(row.keys()):
                    seen.append(row["id"])
                return row
            db.row_factory = read_row
            yield db
            assert db.total_changes == 0

    with monkeypatch.context() as check:
        check.setattr(store, "connection", query_only)
        assert preview(client, base, picks).raise_for_status().json() == wanted
        assert verify(client, base, picks, wanted["sha256"]).raise_for_status().json() == wanted
        refused(verify(client, base, picks, "0" * 64))
    assert scans == [[parent], [parent], [parent]]


def test_concurrent_dismissal_cannot_split_the_preview_snapshot(client, monkeypatch):
    base, (parent, _) = prepare(client)
    row, _ = select(client, base, parent)
    sid = base.split("/")[-1]
    access = deferred_items.access_session

    def concurrent_write(db, request_sid, **kwargs):
        record = access(db, request_sid, **kwargs)
        # Access read the session while the selection was pending. The next transaction dismisses it.
        with store.connection(write=True) as writer:
            writer.execute("""UPDATE deferred_questions SET status='dismissed',revision_id=lower(hex(randomblob(16)))
                              WHERE id=? AND session_id=?""", (row["id"], sid))
        return record

    with monkeypatch.context() as change:
        change.setattr(deferred_items, "access_session", concurrent_write)
        result = preview(client, base, [guard(row)]).raise_for_status().json()
    assert result == expected("1. " + row["question"] + "\n")
    refused(verify(client, base, [guard(row)], result["sha256"]))


@pytest.mark.parametrize("kind", ["empty", "too_many", "duplicate", "bad_id", "bad_version", "extra", "bad_digest"])
def test_selection_shape_is_bounded_and_strict(client, kind):
    base, (parent, _) = prepare(client)
    row, _ = select(client, base, parent)
    item = guard(row)
    invalid = {"empty": [], "too_many": [{**item, "id": str(uuid4())} for _ in range(51)],
               "duplicate": [item, {**item, "id": item["id"].upper()}], "bad_id": [{**item, "id": "no-id"}],
               "bad_version": [{**item, "version": ""}], "extra": [{**item, "question": "Untrusted input"}]}
    if kind == "bad_digest":
        assert verify(client, base, [item], "invalid").status_code == 422
    else:
        assert preview(client, base, invalid[kind]).status_code == 422
        assert verify(client, base, invalid[kind], "0" * 64).status_code == 422


@pytest.mark.parametrize("kind", ["missing", "foreign", "wrong_version", "dismissed", "fulfilled",
                                  "reopened", "reverted_parent", "unflagged_material", "missing_identity"])
def test_unavailable_selection_fails_as_one_generic_result_without_partial_content(client, kind):
    base, (parent, other_parent) = prepare(client)
    ok, _ = select(client, base, other_parent, "Private valid selection?")
    bad, _ = select(client, base, parent, "Private second selection?")
    stale = guard(bad)
    picks = [guard(ok), stale]
    checksum = preview(client, base, picks).raise_for_status().json()["sha256"]
    if kind == "missing":
        stale = {**stale, "id": str(uuid4())}
    elif kind == "foreign":
        other, (foreign_parent, _) = prepare(client)
        foreign, _ = select(client, other, foreign_parent, "Private other interview?")
        stale = guard(foreign)
    elif kind == "wrong_version":
        stale = {**stale, "version": "f" * 64}
    elif kind == "dismissed":
        stale = guard(action(client, base, bad, "dismiss").raise_for_status().json())
    elif kind == "fulfilled":
        client.post(base + "/answers", json=child(bad)).raise_for_status()
        stale = guard(get_item(client, base, bad))
    elif kind == "reopened":
        dismissed = action(client, base, bad, "dismiss").raise_for_status().json()
        action(client, base, dismissed, "reopen", expected_material=receipt(client, base, parent)).raise_for_status()
    elif kind == "reverted_parent":
        path = base + "/answers/" + parent
        changed = client.put(path, json={**PARENT, "answer": "Changed underlying response.",
                             "expected_revision": 1}).raise_for_status().json()
        client.put(path, json={**PARENT, "expected_revision": changed["revision"]}).raise_for_status()
        live = get_item(client, base, bad)
        assert live["needs_reconfirmation"] and live["version"] != bad["version"]
        stale = guard(live)
    elif kind == "unflagged_material":
        # Previously stored content can change independently of the queue flag. Read the actual parent.
        with store.connection(write=True) as db:
            db.execute("UPDATE answers SET answer='Changed private parent' WHERE id=?", (parent,))
        assert guard(get_item(client, base, bad)) == stale
    else:
        with store.connection(write=True) as db:
            db.execute("DELETE FROM answer_instances WHERE answer_id=?", (parent,))
    refused(preview(client, base, [guard(ok), stale]))
    refused(verify(client, base, [guard(ok), stale], checksum))


def test_new_json_restore_has_no_authority_to_verify_the_prior_selection(client, tmp_path, monkeypatch):
    base, (parent, _) = prepare(client)
    row, _ = select(client, base, parent)
    old = [guard(row)]
    issued = preview(client, base, old).raise_for_status().json()
    raw = client.get("/api/backups/workspace").raise_for_status().content
    target = tmp_path / "restored.sqlite"
    store.initialize(target)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(target))
    restore(client, raw, backup_preview(client, raw)).raise_for_status()
    refreshed = get_item(client, base, row)
    assert refreshed["version"] != row["version"]
    refused(preview(client, base, old))
    refused(verify(client, base, old, issued["sha256"]))
    assert verify(client, base, [guard(refreshed)], issued["sha256"]).raise_for_status().json() == issued


def test_parked_draft_does_not_consume_the_question_or_reveal_its_answer(client):
    base, (parent, _) = prepare(client)
    row, _ = select(client, base, parent)
    request = child(row)
    client.put(base + "/draft", json={**request, "expected_revision": 0}).raise_for_status()
    draft = client.get(base + "/draft").raise_for_status().json()
    wanted = expected("1. " + row["question"] + "\n")
    assert preview(client, base, [guard(row)]).raise_for_status().json() == wanted
    assert verify(client, base, [guard(row)], wanted["sha256"]).raise_for_status().json() == wanted
    assert client.get(base + "/draft").json() == draft


@pytest.mark.parametrize(("lost", "status"), [("notice", 403), ("old_hold", 403), ("erased", 403),
                                               ("trash", 404), ("receipt_conflict", 409), ("signout", 401)])
def test_interview_denials_take_precedence_over_question_validation(client, monkeypatch, lost, status):
    base, (parent, _) = prepare(client)
    row, _ = select(client, base, parent)
    picks = [guard(row)]
    issued = preview(client, base, picks).raise_for_status().json()
    sid = base.split("/")[-1]
    if lost == "trash":
        client.post(base + "/trash").raise_for_status()
    elif lost == "signout":
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
        client.cookies.clear()
    else:
        with store.connection(write=True) as db:
            if lost == "erased":
                SessionAnonymizer(db, sid).run(preserve_scorecard_aggregates=False, actor_email="fixture", now_iso=store.timestamp())
            elif lost == "notice":
                db.execute("UPDATE sessions SET consent=0 WHERE id=?", (sid,))
            elif lost == "old_hold":
                db.execute("INSERT INTO legacy_privacy_holds(session_id) VALUES(?)", (sid,))
            else:
                db.execute("INSERT INTO retention_read_holds(session_id) VALUES(?)", (sid,))
    missing = [{**picks[0], "id": str(uuid4())}]
    for result in (preview(client, base, picks), verify(client, base, picks, issued["sha256"]),
                   preview(client, base, missing)):
        assert result.status_code == status and row["question"] not in result.text
        assert result.headers.get("X-InterviewCheck-Conflict") != "deferred-question"
        if lost == "receipt_conflict":
            assert result.headers["X-InterviewCheck-Conflict"] == "interview-privacy"
