"""Exercise the deployed backup code with disposable SQLite databases and shell commands."""
from contextlib import closing
from pathlib import Path
import base64
import os
import sqlite3
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]


def backup_program(tmp_path):
    source = (ROOT / "deploy/backup.sh").read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
    return source.replace('pathlib.Path("/data")', "pathlib.Path(" + repr(str(tmp_path)) + ")")


def test_backup_requires_complete_sources_and_copies_wal_state(tmp_path):
    review = tmp_path / "review.sqlite3"
    with closing(sqlite3.connect(review)) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("CREATE TABLE sample(value TEXT)")
        db.execute("INSERT INTO sample VALUES('current WAL value')")
        db.commit()
        failed = subprocess.run([sys.executable, "-", "missing"], input=backup_program(tmp_path),
                                text=True, capture_output=True)
        assert failed.returncode != 0 and not (tmp_path / ".backups").exists()
        with closing(sqlite3.connect(tmp_path / "access.sqlite3")) as access:
            access.execute("CREATE TABLE sample(value TEXT)")
            access.execute("INSERT INTO sample VALUES('account value')")
            access.commit()
        result = subprocess.run([sys.executable, "-", "complete"], input=backup_program(tmp_path),
                                text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        with closing(sqlite3.connect(tmp_path / ".backups/complete/review.sqlite3")) as saved:
            assert saved.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            assert saved.execute("SELECT value FROM sample").fetchone()[0] == "current WAL value"
        assert (tmp_path / ".backups/complete/access.sqlite3").is_file()


@pytest.mark.skipif(os.name == "nt", reason="The VM rollout executes on Linux with Bash.")
@pytest.mark.parametrize("existing,backup_exit,orphan,expected", [
    (True, 1, False, 1), (True, 0, False, 0), (False, 1, False, 0), (False, 0, True, 1),
])
def test_rollout_stops_before_app_replacement_if_backup_fails(tmp_path, existing, backup_exit, orphan, expected):
    work = tmp_path / "work"
    unit_dir = tmp_path / "units"
    tools = tmp_path / "bin"
    for folder in (work, unit_dir, tools):
        folder.mkdir()
    (work / "app.env").write_text("fixture")
    if orphan:
        (work / "data").mkdir()
        (work / "data/review.sqlite3").write_bytes(b"existing review database")
    log = tmp_path / "docker.log"
    scripts = {
        "docker": """#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ "$*" == *Config.Image* ]]; then
  [ "$CURRENT_PRESENT" = 1 ] && echo old-image || exit 1
elif [[ "$*" == *Health.Status* ]]; then echo healthy
fi
exit 0
""",
        "az": "#!/bin/bash\nexit 0\n",
        "systemctl": "#!/bin/bash\nexit 0\n",
        "chown": "#!/bin/bash\nexit 0\n",
    }
    for name, script in scripts.items():
        target = tools / name
        target.write_text(script)
        target.chmod(0o755)
    body = (ROOT / "deploy/vm-rollout.sh").read_text()
    body = body.replace("/srv/interviewcheck", str(work)).replace("/etc/systemd/system", str(unit_dir))
    rollout = tmp_path / "rollout.sh"
    rollout.write_text(body)
    env = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
           "IMAGE": "new-image", "ACR": "fake", "SITE_ADDRESS": "invalid.test", "BACKUP_ACCOUNT": "fake",
           "CURRENT_PRESENT": "1" if existing else "0", "DOCKER_LOG": str(log)}
    for key, value in {"COMPOSE_B64": "services: {}", "CADDY_B64": "fixture",
                       "BACKUP_B64": "#!/bin/bash\nexit " + str(backup_exit) + "\n"}.items():
        env[key] = base64.b64encode(value.encode()).decode()
    result = subprocess.run(["bash", str(rollout)], env=env, text=True, capture_output=True)
    assert result.returncode == expected, result.stderr
    assert ("compose up" in log.read_text()) == (expected == 0)
    assert (work / "deployed-image").exists() == (expected == 0)
