"""A valid merged-release finding can include a passage outside the current top three."""

import json

from fastapi.testclient import TestClient
from api import store
from api.main import app


def test_restore_old_source_label_ranking_without_accepting_a_fabricated_excerpt(tmp_path, monkeypatch):
    monkeypatch.setenv("INTERVIEWCHECK_DB", str(tmp_path / "upgraded.sqlite"))
    for key in ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_PUBLIC_ORIGIN"):
        monkeypatch.delenv(key, raising=False)
    phrases = [
        " ".join(prefix + str(n) for n in range(length))
        for prefix, length in (("radar", 10), ("optical", 10), ("sensor", 9), ("fluid", 8))
    ]
    refs = [
        {"label": label, "text": text} for label, text in zip(("Repeated", "Repeated", "C", "D"), phrases)
    ]
    with TestClient(app, base_url="http://127.0.0.1", headers={"X-InterviewCheck": "1"}) as client:
        sid = client.post(
            "/api/sessions",
            json={"candidate": "Synthetic", "role": "Engineer", "consent": True, "policy": "Notes allowed"},
        ).json()["id"]
        result = client.post(
            f"/api/sessions/{sid}/answers",
            json={"question": "Which comparison?", "answer": " However ".join(phrases), "references": refs},
        )
        result.raise_for_status()
        answer = result.json()
        assert [p["label"] for p in answer["result"]["passages"]] == ["Repeated", "Repeated", "C"]

        # Verbatim field shape and selected source indices captured from commit 8d8f4de.
        # That scorer deduplicated by label, source offset and word count, omitting source 1.
        historic = {
            **answer["result"],
            "passages": [
                {
                    "label": refs[i]["label"],
                    "words": len(phrases[i].split()),
                    "answer_excerpt": phrases[i],
                    "source_excerpt": phrases[i],
                }
                for i in (0, 2, 3)
            ],
        }
        with store.connection(write=True) as db:
            db.execute("UPDATE answers SET result=? WHERE id=?", (json.dumps(historic), answer["id"]))
        backup = client.get("/api/backups/workspace").content
        dest = tmp_path / "recovered.sqlite"
        store.initialize(dest)
        monkeypatch.setenv("INTERVIEWCHECK_DB", str(dest))
        edited = json.loads(backup)
        edited["sessions"][0]["answers"][0]["result"]["passages"][2]["source_excerpt"] = (
            "Never spoken or supplied."
        )
        assert client.post("/api/backups/preview", json=edited).status_code == 422

        preview = client.post("/api/backups/preview", content=backup)
        assert preview.is_success, preview.text
        restored = client.post(
            "/api/backups/restore",
            content=backup,
            headers={"X-Backup-Preview": preview.json()["fingerprint"]},
        )
        restored.raise_for_status()
        saved = client.get(f"/api/sessions/{sid}/answers/{answer['id']}").json()
        assert saved["result"] == historic
