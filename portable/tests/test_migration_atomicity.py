"""Schema upgrades and per request migrations stay inside one SQLite transaction."""
from contextlib import closing
from pathlib import Path
import sqlite3

import pytest

from api import csp_reports, prompt_templates, retention_policy, role_versions, sql_script, store

API = Path(__file__).resolve().parents[1] / "api"


def schema(path):
    with closing(sqlite3.connect(path)) as db:
        return db.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY rowid").fetchall()


def base_workspace(path):
    """A workspace from the first edition: only the core tables, holding one role."""
    with closing(sqlite3.connect(path)) as db:
        db.executescript(store.SCHEMA)
        db.execute("INSERT INTO roles(id,name,description,questions) VALUES ('r1','Analyst','','[]')")
        db.commit()
    return schema(path)


def test_statements_split_quotes_comments_and_trigger_bodies():
    script = """
    CREATE TABLE t(a TEXT DEFAULT ';'); -- trailing; comment
    CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET a='x;y'; DELETE FROM t WHERE 0; END;
    CREATE INDEX i ON t(a)"""
    parts = sql_script.statements(script)
    assert len(parts) == 3
    assert parts[1].startswith("-- trailing; comment") and parts[1].endswith("END;")
    assert parts[2] == "CREATE INDEX i ON t(a);"
    with pytest.raises(ValueError):
        sql_script.statements("CREATE TABLE broken(a TEXT DEFAULT 'open;")


def test_fresh_upgraded_and_repeated_initialize_produce_one_schema(tmp_path):
    fresh, upgraded = tmp_path / "fresh.sqlite3", tmp_path / "upgraded.sqlite3"
    store.initialize(fresh)
    first = schema(fresh)
    store.initialize(fresh)
    base_workspace(upgraded)
    store.initialize(upgraded)
    assert schema(fresh) == first == schema(upgraded)
    assert {"role_versions", "retention_policies", "csp_violations", "alert_rules"} <= {row[1] for row in first}


@pytest.mark.parametrize("module", [role_versions, retention_policy])
def test_failure_after_a_script_migration_leaves_the_previous_schema(tmp_path, monkeypatch, module):
    path = tmp_path / "review.sqlite3"
    before = base_workspace(path)
    original = module.migrate

    def migrate_then_crash(db):
        original(db)
        raise RuntimeError("power lost mid upgrade")

    monkeypatch.setattr(module, "migrate", migrate_then_crash)
    with pytest.raises(RuntimeError):
        store.initialize(path)
    assert schema(path) == before
    monkeypatch.setattr(module, "migrate", original)
    store.initialize(path)
    with closing(sqlite3.connect(path)) as db:
        assert db.execute("SELECT count(*) FROM role_versions WHERE role_id='r1'").fetchone()[0] == 1


@pytest.mark.parametrize("migrate", [csp_reports.migrate, prompt_templates.migrate])
def test_request_time_migrations_keep_the_request_transaction(tmp_path, monkeypatch, migrate):
    path = tmp_path / "review.sqlite3"
    store.initialize(path)
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(path))
    with pytest.raises(RuntimeError):
        with store.connection(write=True) as db:
            db.execute("DROP TABLE csp_violations")
            db.execute("DROP TABLE prompt_template_versions")
            db.execute("DROP TABLE prompt_templates")
            db.execute("INSERT INTO roles(id,name,description,questions) VALUES ('r2','Planner','','[]')")
            migrate(db)
            raise RuntimeError("request failed after migrating")
    with store.connection() as db:
        assert db.execute("SELECT count(*) FROM roles WHERE id='r2'").fetchone()[0] == 0
        assert db.execute("SELECT count(*) FROM prompt_templates").fetchone()[0] == len(prompt_templates.SLOTS)
        assert db.execute("SELECT count(*) FROM csp_violations").fetchone()[0] == 0


def test_api_modules_run_scripts_without_executescript():
    # retention_policy is migrated through the transaction bound view in store.initialize.
    allowed = {"sql_script.py", "retention_policy.py"}
    offenders = [path.name for path in sorted(API.glob("*.py"))
                 if path.name not in allowed and ".executescript(" in path.read_text(encoding="utf-8")]
    assert offenders == []
