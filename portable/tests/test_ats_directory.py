from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from api import ats_directory as directory
from api.main import app

EMAIL = "sam@example.invalid"


@pytest.mark.parametrize(("provider", "data", "role"), [
    ("workable", [{"candidates": [{"name": "Sam", "email": EMAIL, "job": {"title": "Engineer"}}]}], "Engineer"),
    ("teamtailor", [{"data": [{"attributes": {"first-name": "Sam", "email": EMAIL}}]}], ""),
    ("smartrecruiters", [{"content": [{"firstName": "Sam", "email": EMAIL, "primaryAssignment": {"job": {"title": "Engineer"}}}]}], "Engineer"),
    ("bamboohr", [{"applications": [{"applicant": {"firstName": "Sam", "email": EMAIL}, "job": {"title": {"label": "Engineer"}}}]}], "Engineer"),
    ("recruitee", [{"candidates": [{"name": "Sam", "emails": [EMAIL]}]}], ""),
    ("personio", [{"access_token": "fixture"}, {"_data": [{"candidate": {"first_name": "Sam", "email": EMAIL}, "job": {"name": "Engineer"}}]}], "Engineer"),
    ("jobadder", [{"items": [{"firstName": "Sam", "email": EMAIL}]}], ""),
    ("kombo", [{"data": {"results": [{"first_name": "Sam", "applications": [{"outcome": "PENDING", "job": {"name": "Engineer"}}]}]}}], "Engineer"),
    ("unified", [[{"name": "Sam", "emails": [{"email": EMAIL}], "job_ids": ["job"]}], {"name": "Engineer"}], "Engineer"),
])
def test_directory_lookup(monkeypatch, tmp_path, provider, data, role):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "sessions.sqlite"))
    monkeypatch.delenv("INTERVIEWCHECK_ACCESS_URL", raising=False)
    for key in directory.KEYS[provider]:
        monkeypatch.setenv(key, "fixture")
    wrapped = AsyncMock(side_effect=data)
    monkeypatch.setattr(directory, "fetch_json", wrapped)
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        assert provider in client.get("/api/integrations/status").json()["ats"]
        response = client.post(f"/api/integrations/ats/{provider}/lookup", json={"email": EMAIL})
        assert response.json()["items"] == [{"candidate": "Sam", "role": role}]
