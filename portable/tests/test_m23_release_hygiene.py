"""Tests for M23-W1: model_execution policy split, v8 DR parity, doc dash hygiene, and production audit."""
from pathlib import Path
import shutil
import sys
from types import SimpleNamespace

from fastapi import HTTPException
import pytest

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from api import account_db, model_execution, model_execution_policy, ssrf_guard  # noqa: E402
from scripts import dr_drill, run_production_audit  # noqa: E402
W4_UI_FILES = {
    "portable/web/components/admin/AuditLogTab.tsx",
    "portable/web/components/admin/ModelSummaryCards.tsx",
}
OWNED_DOCS = (
    "docs/DISASTER-RECOVERY.md",
    "docs/ARCHITECTURE.md",
    "docs/CONNECTORS.md",
    "docs/LIVE-TEST-CHECKLIST.md",
    "docs/OVERNIGHT-2026-11-08.md",
    "docs/backend-plan.md",
    "docs/native-app-plan.md",
    "docs/next-level-plan.md",
)


def _line_count(rel_path: str) -> int:
    return len((ROOT / rel_path).read_text(encoding="utf-8").splitlines())


def test_model_execution_policy_reexports_and_line_caps():
    assert _line_count("portable/api/model_execution_policy.py") <= 85
    assert _line_count("portable/api/model_execution.py") <= 365
    assert _line_count("scripts/dr_drill.py") <= 282
    assert _line_count("docs/DISASTER-RECOVERY.md") <= 140
    assert _line_count("RELEASE_AUDIT.md") <= 160
    for rel in OWNED_DOCS:
        text = (ROOT / rel).read_text(encoding="utf-8")
        assert len(text.splitlines()) <= 400
        assert "\u2014" not in text and "\u2013" not in text

    for attr in (
        "ModelQuotaLimiter", "QUOTA_LIMITER", "reset_quotas",
        "_is_ssrf_error", "_safe_finite_float", "_safe_timeout", "_clamped_retries", "_rpm_limit",
    ):
        assert getattr(model_execution, attr) is getattr(model_execution_policy, attr)
    assert callable(model_execution.asyncio.sleep)

    assert model_execution._safe_timeout(float("inf"), default=30.0, low=1.0, high=180.0) == 30.0
    assert model_execution._safe_timeout(500.0, default=30.0, low=1.0, high=180.0) == 180.0
    assert model_execution._clamped_retries(SimpleNamespace(config={"max_retries": 9})) == 3
    assert model_execution._rpm_limit(SimpleNamespace(config={"rpm_limit": True})) is None
    assert model_execution._rpm_limit(SimpleNamespace(config={"rpm_limit": 5})) == 5

    err = HTTPException(400, "blocked")
    err.__cause__ = ssrf_guard.SSRFValidationError("private IP")
    assert model_execution._is_ssrf_error(err) is True

    model_execution.reset_quotas()
    model_execution.QUOTA_LIMITER.consume("m23-test-model", 1)
    with pytest.raises(HTTPException) as exc:
        model_execution.QUOTA_LIMITER.consume("m23-test-model", 1)
    assert exc.value.status_code == 429
    model_execution.reset_quotas()
    model_execution.QUOTA_LIMITER.consume("m23-test-model", 1)
    model_execution.reset_quotas()


def test_dr_drill_and_docs_version_eight_parity(tmp_path):
    assert account_db.VERSION == 8
    report = dr_drill.run_drill(tmp_path / "dr")
    assert report["ok"] is True
    assert report["sqlite_backup"]["access_user_version"] == account_db.VERSION

    dr_doc = (ROOT / "docs/DISASTER-RECOVERY.md").read_text(encoding="utf-8")
    assert "(v8)" in dr_doc and "== 8" in dr_doc and "!= 8" in dr_doc
    assert "v7" not in dr_doc and "== 7" not in dr_doc and "!= 7" not in dr_doc

    audit_doc = (ROOT / "RELEASE_AUDIT.md").read_text(encoding="utf-8")
    assert "## 6." in audit_doc and "run_production_audit.py --with-dr --json" in audit_doc
    assert "\u2014" not in audit_doc and "\u2013" not in audit_doc


def test_production_audit_with_dr_and_clean_root_verification(tmp_path):
    report = run_production_audit.run_audit(ROOT, with_dr=True)
    by_id = {c["id"]: c for c in report["checks"]}
    for check_id in (
        "source_size_backend", "source_size_web_docs", "deploy_config", "edge_security_asgi", "dr_drill",
    ):
        assert by_id[check_id]["ok"] is True, by_id[check_id]

    offenders = set(by_id["zero_em_en_dashes"]["data"]["offenders"])
    assert offenders <= W4_UI_FILES, f"Unexpected em/en dash offenders: {sorted(offenders - W4_UI_FILES)}"

    if not offenders:
        assert report["ok"] is True
        return

    clean_root = tmp_path / "clean_repo"
    shutil.copytree(
        ROOT,
        clean_root,
        ignore=shutil.ignore_patterns(".git", ".venv", "node_modules", ".next*", "out", "__pycache__", "data"),
    )
    for rel in W4_UI_FILES:
        target = clean_root / rel
        if target.is_file():
            cleaned = target.read_text(encoding="utf-8").replace("\u2014", "-").replace("\u2013", "-")
            target.write_text(cleaned, encoding="utf-8")

    clean_report = run_production_audit.run_audit(clean_root, with_dr=True)
    assert clean_report["ok"] is True, clean_report["errors"]
