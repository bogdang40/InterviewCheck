import json
import sqlite3
from contextlib import closing

import pytest

from api import store
from api.migrate import import_role, migrate
from api.report import report


def profile():
    return {"workspaceID": "role-123", "name": "Engineer", "company": "Sample", "jobDescription": "Design APIs",
            "plannedQuestions": [{"text": "Walk me through a design.", "strongAnswer": "Discuss constraints."}],
            "cheaterPrompts": [{"name": "Full", "instructions": "Generate a reference.", "isEnabled": True}]}


def build_native(path):
    with closing(sqlite3.connect(path)) as db, db:
        db.executescript("""
          CREATE TABLE role_profiles(workspace_id TEXT PRIMARY KEY, profile TEXT);
          CREATE TABLE interviews(id TEXT PRIMARY KEY, candidate_name TEXT, role_title TEXT, consent_confirmed_at INTEGER,
                                  started_at INTEGER, ended_at INTEGER, overall_percent INTEGER);
          CREATE TABLE interview_questions(id TEXT PRIMARY KEY, interview_id TEXT, ordinal INTEGER, text TEXT, answer_text TEXT);
          CREATE TABLE reference_answers(question_id TEXT, provider TEXT, model TEXT, prompt_name TEXT, text TEXT, error TEXT);
          CREATE TABLE answer_scores(question_id TEXT PRIMARY KEY, percent INTEGER, reasons TEXT, metrics TEXT);
          CREATE TABLE answer_notes(question_id TEXT PRIMARY KEY, note TEXT);
          CREATE TABLE answer_labels(question_id TEXT PRIMARY KEY, label TEXT);
          INSERT INTO interviews VALUES ('i','Example','Developer',NULL,1609459200000,1609462800000,91);
          INSERT INTO interview_questions VALUES ('q','i',1,'How?','My answer.');
          INSERT INTO reference_answers VALUES ('q','openai','sample','copilot','A reference text.',NULL);
          INSERT INTO answer_scores VALUES ('q',91,'["wording"]','{"firstWordLatency":2}');
          INSERT INTO answer_notes VALUES ('q','Clarified under questioning.');
          INSERT INTO answer_labels VALUES ('q','genuine');
        """)
        db.execute("INSERT INTO role_profiles VALUES (?,?)", ("role-123", json.dumps(profile())))


def test_import_preserves_source_and_legacy_report(tmp_path):
    source, target = tmp_path / "native.db", tmp_path / "portable.db"
    build_native(source)
    original = source.read_bytes()
    assert migrate(source, target) == {"sessions": 1, "answers": 1, "roles": 1}
    assert migrate(source, target) == {"sessions": 0, "answers": 0, "roles": 0}
    assert source.read_bytes() == original
    with store.connection(target) as db:
        key = db.execute("SELECT id FROM sessions").fetchone()[0]
        session = store.get_session(db, key)
        role = store.role_row(db.execute("SELECT * FROM roles").fetchone())
    assert session["consent"] is False
    assert session["created_at"].startswith("2021-01-01")
    assert session["review_count"] == 0
    entry, = session["answers"]
    assert entry["legacy"]["score"]["metrics"]["firstWordLatency"] == 2
    assert entry["result"]["status"] == "insufficient"
    assert entry["legacy"]["label"]["label"] == "genuine"
    assert entry["note"] == "Clarified under questioning."
    assert "wording" in report(session)
    assert role["name"] == "Engineer at Sample"
    assert role["questions"] == ["Walk me through a design."]
    assert role["legacy"] == profile()


def test_broken_import_rolls_back_all_rows(tmp_path):
    source, target = tmp_path / "broken.db", tmp_path / "portable.db"
    build_native(source)
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("UPDATE answer_scores SET metrics='broken'")
    with pytest.raises(ValueError):
        migrate(source, target)
    with store.connection(target) as db:
        assert db.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM roles").fetchone()[0] == 0


def test_old_native_snapshot_with_no_note_or_verdict_table(tmp_path):
    source, target = tmp_path / "old.db", tmp_path / "portable.db"
    build_native(source)
    with closing(sqlite3.connect(source)) as db, db:
        db.execute("DROP TABLE answer_notes")
        db.execute("DROP TABLE answer_labels")
    assert migrate(source, target)["sessions"] == 1
    with store.connection(target) as db:
        entry = store.answer_row(db.execute("SELECT * FROM answers").fetchone())
    assert entry["note"] == ""
    assert "label" not in entry["legacy"]


def test_same_database_rejected(tmp_path):
    source = tmp_path / "native.db"
    build_native(source)
    with pytest.raises(ValueError):
        migrate(source, source)


def test_native_role_export_is_idempotent(tmp_path):
    role = tmp_path / "role.json"
    target = tmp_path / "target.sqlite"
    doc = {"format": "interviewcheck.role", "version": 1, "role": profile()}
    role.write_text(json.dumps(doc))
    assert migrate(role, target)["roles"] == 1
    with store.connection(target, write=True) as db:
        added, record = import_role(db, doc)
        assert not added
        assert record["legacy"] == doc["role"]
        with pytest.raises(ValueError):
            import_role(db, dict(doc, version=2))


def test_current_native_schema_statements_and_report_fields(tmp_path):
    """Construct a v22 snapshot with the product's actual DDL on all platforms."""
    import re
    from pathlib import Path

    schema_source = Path(__file__).resolve().parents[2] / "InterviewCheck/Database/InterviewSchema.swift"
    sql_literals = re.findall(r'"""(.*?)"""|"(CREATE (?:UNIQUE )?INDEX [^"]+|ALTER TABLE [^"]+)"',
                              schema_source.read_text(encoding="utf-8"), re.DOTALL)
    native, target = tmp_path / "v22.db", tmp_path / "workspace.db"
    with closing(sqlite3.connect(native)) as db, db:
        for multiline, line in sql_literals:
            sql = (multiline or line).strip()
            if sql.startswith(("CREATE ", "ALTER ")):
                db.execute(sql)
        db.execute("""INSERT INTO interviews (id,role_title,candidate_name,consent_confirmed_at,started_at,interrupted,scored_from)
                      VALUES ('native-id','SRE','Sample',1000,2000,1,'transcript')""")
        db.execute("""INSERT INTO interview_questions (id,interview_id,ordinal,text,source,marked_at_ms,answer_text)
                      VALUES ('q','native-id',1,'What would you change?','live',2000,'The queue capacity.')""")
        db.execute("""INSERT INTO reference_answers
                      (id,question_id,provider,model,prompt_name,text,error)
                      VALUES ('r','q','openai','sample','Full answer','Partial output','Provider error')""")
        db.execute("""INSERT INTO answer_scores VALUES ('q',37,'low','[]','["Short answer"]','["Can you elaborate?"]',
                      '{"wordCount":3}',1,3000)""")
        db.execute("INSERT INTO answer_labels VALUES ('q','genuine',4000)")
        db.execute("INSERT INTO answer_notes VALUES ('q','Original note',4001)")
        db.execute("INSERT INTO role_profiles VALUES ('role-123',?,4002)", (json.dumps(profile()),))
    totals = migrate(native, target)
    assert totals == {"sessions": 1, "roles": 1, "answers": 1}
    with store.connection(target) as db:
        key = db.execute("SELECT id FROM sessions").fetchone()[0]
        migrated = store.get_session(db, key)
    assert migrated["consent"] is True
    assert migrated["legacy"]["scored_from"] == "transcript"
    assert migrated["legacy"]["interrupted"] == 1
    answer, = migrated["answers"]
    assert not answer["references"]
    assert answer["legacy"]["reference_answers"][0]["error"] == "Provider error"
    assert answer["legacy"]["score"]["follow_ups"] == ["Can you elaborate?"]
