from pathlib import Path

from fastapi.testclient import TestClient
import pytest

from api.main import app


@pytest.mark.parametrize("failed_store", ["review", "account"])
def test_health_detects_unavailable_store_without_recreating_it(tmp_path, monkeypatch, failed_store):
    paths = {"review": tmp_path / "review.sqlite", "account": tmp_path / "account.sqlite"}
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(paths["review"]))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_DB", str(paths["account"]))
    monkeypatch.setenv("INTERVIEWCHECK_ACCESS_MODE", "embedded")
    monkeypatch.delenv("INTERVIEWCHECK_PUBLIC_ORIGIN", raising=False)
    with TestClient(app, base_url="http://127.0.0.1") as client:
        assert client.get("/api/health").json() == {"ok": True}
        key = "INTERVIEWCHECK_DB" if failed_store == "review" else "INTERVIEWCHECK_ACCESS_DB"
        missing = tmp_path / (failed_store + "-missing.sqlite")
        monkeypatch.setenv(key, str(missing))
        result = client.get("/api/health")
        assert result.status_code == 503 and not missing.exists()
        assert str(tmp_path) not in result.text
        monkeypatch.setenv(key, str(paths[failed_store]))
        assert client.get("/api/health").status_code == 200
