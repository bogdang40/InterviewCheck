"""Compare catalog and admin routes on a 5,000 session, 30,000 exchange, 500 user, 5,000 audit workspace."""

import json
import os
from pathlib import Path
import statistics
import sys
import tempfile
import time
from unittest.mock import patch
from uuid import UUID, uuid4

from fastapi.testclient import TestClient

# Support running directly from the portable directory without installing the app.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from api import access, account_db, store  # noqa: E402
from api.main import app  # noqa: E402

SESSIONS = 5000
ANSWERS_PER_SESSION = 6
USERS = 500
AUDIT_ROWS = 5000
AUDIT_ACTIONS = (
    "admin.model.probe",
    "admin.model.create",
    "admin.update_user",
    "auth.login",
    "auth.logout",
)


def seed_workspace():
    ids = [str(UUID(int=i + 1)) for i in range(SESSIONS)]
    with store.connection(write=True) as db:
        db.executemany(
            "INSERT INTO sessions (id,candidate,role,policy,consent,created_at) VALUES (?,?,?,?,?,?)",
            (
                (
                    key,
                    f"Fixture {i:04}",
                    "Firmware engineer",
                    "Public documentation permitted.",
                    1,
                    f"2026-01-{1 + i % 28:02}T{i % 24:02}:{(i // 24) % 60:02}:00Z",
                )
                for i, key in enumerate(ids)
            ),
        )
        db.executemany(
            "INSERT INTO session_context (session_id,ended_at) VALUES (?,?)",
            ((key, None if i % 2 else "2026-02-01T00:00:00Z") for i, key in enumerate(ids)),
        )
        db.executemany(
            "INSERT INTO answers (id,session_id,question,answer,refs,result,status) VALUES (?,?,?,?,?,?,?)",
            (
                (
                    str(UUID(int=10000 + i * ANSWERS_PER_SESSION + j)),
                    key,
                    f"Which clock changes at step {j}?",
                    (
                        "Telemetry synchronization requires an independent oscillator while the primary source is being calibrated."
                    ),
                    "[]",
                    "{}",
                    "match" if i % 3 == j else "no_match",
                )
                for i, key in enumerate(ids)
                for j in range(ANSWERS_PER_SESSION)
            ),
        )


def seed_access(admin_id: str):
    base_ms = 1_760_000_000_000
    user_ids = [admin_id] + [str(uuid4()) for _ in range(USERS - 1)]
    with account_db.connection(write=True) as db:
        db.executemany(
            "INSERT INTO users(id,email,password_hash,role,disabled,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
            (
                (
                    uid,
                    f"profile-user-{idx:04}@example.invalid",
                    account_db.DECOY,
                    "user",
                    0,
                    base_ms + idx * 1000,
                    base_ms + idx * 1000,
                )
                for idx, uid in enumerate(user_ids[1:], start=1)
            ),
        )
        db.executemany(
            "INSERT INTO audit_log(at,actor_user_id,action,target_user_id,details) VALUES (?,?,?,?,?)",
            (
                (
                    base_ms + i * 500,
                    user_ids[i % len(user_ids)],
                    AUDIT_ACTIONS[i % len(AUDIT_ACTIONS)],
                    user_ids[(i + 1) % len(user_ids)],
                    json.dumps({"seq": i, "slug": f"model-{i % 10}"}),
                )
                for i in range(AUDIT_ROWS)
            ),
        )


def run():
    with (
        tempfile.TemporaryDirectory() as temp,
        patch.dict(
            os.environ,
            {
                "INTERVIEWCHECK_DB": temp + "/benchmark.sqlite",
                "INTERVIEWCHECK_ACCESS_DB": temp + "/access.sqlite",
                "INTERVIEWCHECK_ACCESS_URL": "",
                "INTERVIEWCHECK_ACCESS_MODE": "embedded",
                "INTERVIEWCHECK_PUBLIC_ORIGIN": "",
                "INTERVIEWCHECK_OPERATOR_EMAIL": "",
                "ADMIN_EMAILS": "profile-admin@example.invalid",
                "ADMIN_BOOTSTRAP_SECRET": "profile-bootstrap-secret",
            },
        ),
    ):
        with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
            signup = client.post(
                "/api/integrations/access/signup",
                json={
                    "email": "profile-admin@example.invalid",
                    "password": "profile-admin-password-123",
                    "adminSecret": "profile-bootstrap-secret",
                },
            )
            signup.raise_for_status()
            token = client.cookies[access.COOKIE]
            auth_headers = {"Authorization": f"Bearer {token}"}
            me = client.get("/v1/me", headers=auth_headers)
            me.raise_for_status()
            admin_id = me.json()["user"]["id"]

            seed_workspace()
            seed_access(admin_id)

            cases = [
                ("Legacy summaries", "GET", "/api/sessions", {}),
                ("Archive first page", "GET", "/api/interviews/feed", {}),
                ("Archive page 100", "GET", "/api/interviews/feed?page=100", {}),
                ("Archive + pending", "GET", "/api/interviews/feed?review=pending&sort=pending", {}),
                ("Overview", "GET", "/api/interviews/overview", {}),
                ("Search common answer", "POST", "/api/search", {"json": {"query": "oscillator"}}),
                ("Search exact candidate", "POST", "/api/search", {"json": {"query": "Fixture 4999"}}),
                ("Admin audit (5k)", "GET", "/v1/admin/audit?limit=50", {"headers": auth_headers}),
                (
                    "Admin audit filtered",
                    "GET",
                    "/v1/admin/audit?action=admin.model.probe&limit=50",
                    {"headers": auth_headers},
                ),
                ("Admin accounts (500)", "GET", "/v1/admin/users?limit=50", {"headers": auth_headers}),
            ]

            for label, method, path, args in cases:
                timings = []
                response = None
                for _ in range(5):
                    start = time.perf_counter()
                    response = client.request(method, path, **args)
                    response.raise_for_status()
                    timings.append(1000 * (time.perf_counter() - start))
                assert response is not None
                print(
                    f"{label:23} {len(response.content):>10,} bytes   median {statistics.median(timings):6.1f} ms"
                )


if __name__ == "__main__":
    run()
