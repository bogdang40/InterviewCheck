"""Run the portable client against the repository's real account service."""
from contextlib import closing, contextmanager
import os
from pathlib import Path
import subprocess
import sqlite3
import time

import httpx
import pytest
from fastapi.testclient import TestClient


# Bind only to loopback and ask the OS for a free port. The service classes
# and routes are the same ones instantiated by server/src/index.ts.
LAUNCH = """
import { serve } from '@hono/node-server';
import { writeFileSync } from 'node:fs';
import { Container } from './dist/Container.js';
import { AppFactory } from './dist/http/App.js';
import { AppConfigLoader } from './dist/config/AppConfig.js';
const container = new Container(AppConfigLoader.fromEnvironment());
container.prepare();
serve({fetch: AppFactory.create(container).fetch, hostname:'127.0.0.1', port:0},
      addr => writeFileSync(process.env.IC_PORT_FILE, String(addr.port)));
"""


@contextmanager
def access_service(directory, scratch):
    if not (directory / "dist/Container.js").exists():
        pytest.fail("Build the original account service with npm ci and npm run build in server/.")
    port_file = scratch / "access-port"
    environment = {key: value for key, value in os.environ.items()
                   if key.lower() in {"path", "systemroot", "temp", "tmp", "tmpdir"}}
    environment.update(DATABASE_PATH=str(scratch / "access.sqlite"),
                       IC_PORT_FILE=str(port_file), TRIAL_DAYS="3")
    with subprocess.Popen(["node", "--input-type=module", "--eval", LAUNCH],
                          cwd=directory, env=environment) as process:
        try:
            deadline = time.monotonic() + 15
            while not port_file.exists() or not port_file.read_text().strip():
                if process.poll() is not None or time.monotonic() > deadline:
                    pytest.fail("The original account service did not start within 15 seconds.")
                time.sleep(0.05)
            yield "http://127.0.0.1:" + port_file.read_text().strip()
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()


def test_membership_session_uses_native_access_contract(workspace_url, tmp_path, monkeypatch):
    service_dir = Path(__file__).resolve().parents[2] / "server"
    identity = {"email": "fixture@example.test", "password": "Synthetic-access-test-4231"}
    with access_service(service_dir, tmp_path) as address:
        monkeypatch.setenv("INTERVIEWCHECK_ACCESS_URL", address)
        monkeypatch.setenv("INTERVIEWCHECK_OPERATOR_EMAIL", identity["email"])
        with httpx.Client(base_url=workspace_url, headers={"X-InterviewCheck": "1"}) as client:
            assert client.get("/api/sessions").status_code == 401
            base = "/api/integrations/"
            created = client.post(base + "access/signup", json=identity)
            created.raise_for_status()
            assert created.json() == {"email": identity["email"], "active": True}
            assert client.get(base + "account").json()["active"]
            assert client.get("/api/sessions").status_code == 200
            assert client.post(base + "billing/checkout", json={"plan": "monthly"}).status_code == 503
            assert client.post(base + "logout").is_success
            assert client.get("/api/sessions").status_code == 401
            assert client.post(base + "access/login", json=identity).is_success
            assert client.get("/api/roles").status_code == 200


def test_account_backup_can_switch_runtimes(tmp_path, monkeypatch):
    from api.account_server import app as python_accounts

    service_dir = Path(__file__).resolve().parents[2] / "server"
    restored = tmp_path / "restored"
    restored.mkdir()
    source_db = tmp_path / "access.sqlite"
    restored_db = restored / "access.sqlite"
    identity = {"email": "restore@example.test", "password": "Synthetic-recovery-test-3182"}
    with access_service(service_dir, tmp_path) as address, httpx.Client(base_url=address, trust_env=False) as node:
        account = node.post("/v1/auth/signup", json=identity).raise_for_status().json()
        token = {"Authorization": "Bearer " + account["token"]}
        with closing(sqlite3.connect(source_db)) as source, closing(sqlite3.connect(restored_db)) as destination:
            source.backup(destination)
            assert destination.execute("PRAGMA integrity_check").fetchone() == ("ok",)
            destination.execute("ALTER TABLE subscriptions DROP COLUMN stripe_customer_id")
            destination.execute("PRAGMA user_version=4")
            destination.commit()
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(restored_db))
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(restored / "review.sqlite"))
    with TestClient(python_accounts) as python:
        recovered = python.get("/v1/me", headers=token).raise_for_status().json()
        assert recovered["user"]["id"] == account["user"]["id"]
        assert recovered["entitlement"]["source"] == "trial"
        assert python.post("/v1/auth/logout", headers=token).status_code == 204
    with closing(sqlite3.connect(restored_db)) as destination:
        assert destination.execute("PRAGMA user_version").fetchone() == (5,)
        destination.execute("PRAGMA user_version=4")  # Also resume an interim database with the column already present.
    with access_service(service_dir, restored) as address, httpx.Client(base_url=address, trust_env=False) as node:
        assert node.get("/v1/me", headers=token).status_code == 401
        logged_in = node.post("/v1/auth/login", json=identity).raise_for_status().json()
        assert logged_in["user"]["id"] == account["user"]["id"]
    with closing(sqlite3.connect(restored_db)) as destination:
        assert destination.execute("PRAGMA user_version").fetchone() == (5,)
