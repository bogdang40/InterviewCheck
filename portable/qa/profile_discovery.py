"""Compare catalog routes on a synthetic 5,000 session, 30,000 exchange workspace."""

import os
from pathlib import Path
import statistics
import tempfile
import time
from unittest.mock import patch
from uuid import UUID

from fastapi.testclient import TestClient

# Support running directly from the portable directory without installing the app.
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from api import store
from api.main import app


def seed():
    ids = [str(UUID(int=i + 1)) for i in range(5000)]
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
                    f"2026-01-{1 + i % 28:02}T00:00:00Z",
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
                    str(UUID(int=10000 + i * 6 + j)),
                    key,
                    f"Which clock changes at step {j}?",
                    "Telemetry synchronization requires an independent oscillator while the primary source is being calibrated.",
                    "[]",
                    "{}",
                    "match" if i % 3 == j else "no_match",
                )
                for i, key in enumerate(ids)
                for j in range(6)
            ),
        )


def run():
    with (
        tempfile.TemporaryDirectory() as temp,
        patch.dict(
            os.environ,
            {
                "INTERVIEWCHECK_DB": temp + "/benchmark.sqlite",
                "INTERVIEWCHECK_ACCESS_URL": "",
                "INTERVIEWCHECK_ACCESS_MODE": "",
                "INTERVIEWCHECK_PUBLIC_ORIGIN": "",
            },
        ),
    ):
        with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
            seed()
            for label, method, path, args in [
                ("Legacy summaries", "GET", "/api/sessions", {}),
                ("Archive first page", "GET", "/api/interviews/feed", {}),
                ("Archive + pending", "GET", "/api/interviews/feed?review=pending&sort=pending", {}),
                ("Overview", "GET", "/api/interviews/overview", {}),
                ("Search common answer", "POST", "/api/search", {"json": {"query": "oscillator"}}),
                ("Search exact candidate", "POST", "/api/search", {"json": {"query": "Fixture 4999"}}),
            ]:
                timings = []
                for _ in range(5):
                    start = time.perf_counter()
                    response = client.request(method, path, **args)
                    response.raise_for_status()
                    timings.append(1000 * (time.perf_counter() - start))
                print(
                    f"{label:23} {len(response.content):>10,} bytes   median {statistics.median(timings):6.1f} ms"
                )


if __name__ == "__main__":
    run()
