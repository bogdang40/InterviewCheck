"""Tests for M26-W1: production audit hardening, bundle budget check, and release docs parity."""
from __future__ import annotations

from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts import run_production_audit  # noqa: E402


def _make_synthetic_bundle(root: Path, *, chunk_bytes: int = 1024, chunk_text: str = "console.log('ok');") -> Path:
    out_dir = root / "portable" / "web" / "out"
    chunks_dir = out_dir / "_next" / "static" / "chunks"
    chunks_dir.mkdir(parents=True, exist_ok=True)
    chunk = chunks_dir / "app-main.js"
    padded = chunk_text + (" " * max(0, chunk_bytes - len(chunk_text.encode("utf-8"))))
    chunk.write_text(padded, encoding="utf-8")
    html = (
        "<!doctype html><html><head>"
        "<script src=\"/_next/static/chunks/polyfill.js\" nomodule=\"\"></script>"
        "<script src=\"/_next/static/chunks/app-main.js\"></script>"
        "</head><body>ok</body></html>"
    )
    (out_dir / "index.html").write_text(html, encoding="utf-8")
    (out_dir / "admin").mkdir(parents=True, exist_ok=True)
    (out_dir / "admin" / "index.html").write_text(html, encoding="utf-8")
    return out_dir


def test_root_text_files_scanned_for_dashes_and_line_caps(tmp_path: Path):
    for rel in run_production_audit.ROOT_TEXT_FILES:
        src = ROOT / rel
        if src.is_file():
            dst = tmp_path / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

    assert run_production_audit.check_zero_dashes(tmp_path).ok is True
    assert run_production_audit.check_web_and_docs_line_limit(tmp_path).ok is True

    readme = tmp_path / "README.md"
    readme.write_text(readme.read_text(encoding="utf-8") + "\nInjected \u2014 em dash\n", encoding="utf-8")
    inject_csp = tmp_path / "portable" / "web" / "inject-csp.mjs"
    inject_csp.write_text(inject_csp.read_text(encoding="utf-8") + "\n// \u2014 dash\n", encoding="utf-8")

    dash_res = run_production_audit.check_zero_dashes(tmp_path)
    assert dash_res.ok is False
    assert set(dash_res.data["offenders"]) == {"README.md", "portable/web/inject-csp.mjs"}

    readme.write_text("\n".join(["line"] * 405) + "\n", encoding="utf-8")
    size_res = run_production_audit.check_web_and_docs_line_limit(tmp_path)
    assert size_res.ok is False
    assert any(v.startswith("README.md: 405") for v in size_res.data["violations"])


def test_web_bundle_budget_passes_and_fails_closed(tmp_path: Path):
    missing_res = run_production_audit.check_web_bundle_budget(tmp_path)
    assert missing_res.ok is False
    assert missing_res.id == "web_bundle_budget"

    _make_synthetic_bundle(tmp_path, chunk_bytes=2048)
    ok_res = run_production_audit.check_web_bundle_budget(tmp_path)
    assert ok_res.ok is True, ok_res.detail
    assert ok_res.data["routes_checked"] == 2
    assert ok_res.data["max_route_bytes"] == 2048

    _make_synthetic_bundle(tmp_path, chunk_bytes=614_400)
    oversize_res = run_production_audit.check_web_bundle_budget(tmp_path)
    assert oversize_res.ok is False
    assert any("614400 B >= 614400 B" in v for v in oversize_res.data["violations"])

    _make_synthetic_bundle(tmp_path, chunk_bytes=512, chunk_text="import 'framer-motion';")
    forbidden_res = run_production_audit.check_web_bundle_budget(tmp_path)
    assert forbidden_res.ok is False
    assert any("framer-motion" in v for v in forbidden_res.data["violations"])

    _make_synthetic_bundle(tmp_path, chunk_bytes=512, chunk_text="const leak = 'encrypted_api_key';")
    secret_res = run_production_audit.check_web_bundle_budget(tmp_path)
    assert secret_res.ok is False
    assert any("encrypted_api_key" in v for v in secret_res.data["violations"])


def test_release_docs_parity_and_line_caps():
    readme_text = (ROOT / "README.md").read_text(encoding="utf-8")
    readme_lines = readme_text.splitlines()
    assert len(readme_lines) <= 195
    assert "\u2014" not in readme_text and "\u2013" not in readme_text
    assert "three.js" not in readme_text.lower()
    assert "framer motion" not in readme_text.lower()
    assert "/admin/" in readme_text
    assert "/interviews/compare/" in readme_text
    assert "run_production_audit.py" in readme_text

    audit_text = (ROOT / "RELEASE_AUDIT.md").read_text(encoding="utf-8")
    audit_lines = audit_text.splitlines()
    assert len(audit_lines) <= 155
    assert "\u2014" not in audit_text and "\u2013" not in audit_text
    assert "## 6." in audit_text
    assert "run_production_audit.py --with-dr --json" in audit_text
    for milestone in ("M23", "M24", "M25", "M26"):
        assert milestone in audit_text

    audit_script_lines = (ROOT / "scripts" / "run_production_audit.py").read_text(encoding="utf-8").splitlines()
    assert len(audit_script_lines) <= 295
    assert len(Path(__file__).read_text(encoding="utf-8").splitlines()) <= 160


def test_run_audit_with_bundle_flag_optional(tmp_path: Path):
    base_report = run_production_audit.run_audit(ROOT, with_dr=False, with_bundle=False)
    assert base_report["with_bundle"] is False
    assert "web_bundle_budget" not in {c["id"] for c in base_report["checks"]}

    missing_root = tmp_path / "empty_repo"
    missing_root.mkdir()
    check = run_production_audit.check_web_bundle_budget(missing_root)
    assert check.ok is False
