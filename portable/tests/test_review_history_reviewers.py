"""Answer history (#7) combined with per-reviewer decisions (M12): one history row per answer revision."""
from api import store
from api.models import AnswerInput, ReviewInput, SessionInput


def test_second_reviewer_with_same_decision_saves_without_a_duplicate_revision(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "review.sqlite3"))
    store.initialize(store.db_path())
    with store.connection(write=True) as db:
        session = store.create_session(db, SessionInput(candidate="Ana", role="Engineer", policy="No AI tools.", consent=True))
        answer = store.write_answer(db, session["id"], AnswerInput(question="Why?", answer="Because."))
        first = store.update_review(db, session["id"], answer["id"], ReviewInput(disposition="explained", note="ok"),
                                    actor=("reviewer-a", "a@example.invalid"))
        # Reviewer B records the same decision: the answer row does not change, B's decision does.
        second = store.update_review(db, session["id"], answer["id"], ReviewInput(disposition="explained", note="ok"),
                                     actor=("reviewer-b", "b@example.invalid"))
        revisions = [row["revision"] for row in db.execute(
            "SELECT revision FROM answer_history WHERE answer_id=? ORDER BY revision", (answer["id"],))]
        events = db.execute("SELECT count(*) FROM answer_review_events WHERE answer_id=?", (answer["id"],)).fetchone()[0]
    assert second["revision"] == first["revision"]
    assert revisions == [answer["revision"], first["revision"]]
    assert events == 2
