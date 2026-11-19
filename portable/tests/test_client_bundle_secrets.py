"""Tests for M2 F9: verify zero secrets, server env var names, or NEXT_PUBLIC_ leaks in client source and bundle."""
import os
from pathlib import Path
import re

import pytest

WEB_ROOT = Path(__file__).resolve().parents[1] / "web"
OUT_DIR = WEB_ROOT / "out"

SECRET_PATTERNS = (
    re.compile(r"\bsk-(?:proj-|svcacct-|admin-|ant-api\d+-)?[A-Za-z0-9]{20,}\b"),
    re.compile(r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b"),
    re.compile(r"\bwhsec_[A-Za-z0-9]{16,}\b"),
    re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{20,}\b"),
    re.compile(r"\b(?:ghp_|github_pat_)[A-Za-z0-9_]{16,}\b"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"\bNEXT_PUBLIC_"),
)

SERVER_ENV_NAMES = (
    "ADMIN_BOOTSTRAP_SECRET",
    "INTERVIEWCHECK_MODEL_SECRET_KEY",
    "INTERVIEWCHECK_SIGNUP_SECRET",
    "STRIPE_SECRET_KEY",
    "STRIPE_WEBHOOK_SECRET",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "DEEPGRAM_API_KEY",
    "IMAP_PASSWORD",
)


def test_client_source_has_no_env_or_next_public_references():
    for folder in ("app", "components", "lib"):
        for path in (WEB_ROOT / folder).rglob("*"):
            if path.is_file() and path.suffix in {".ts", ".tsx", ".js", ".jsx"}:
                text = path.read_text(encoding="utf-8")
                assert "NEXT_PUBLIC_" not in text, f"NEXT_PUBLIC_ found in {path}"
                assert "process.env." not in text, f"process.env. found in {path}"


def test_client_bundle_out_has_no_secrets_or_server_env_names():
    if not OUT_DIR.is_dir():
        if os.getenv("INTERVIEWCHECK_REQUIRE_WEB_OUT") == "1":
            pytest.fail(f"Expected built static bundle at {OUT_DIR}")
        pytest.skip("portable/web/out not built")
    files = [p for p in OUT_DIR.rglob("*") if p.is_file() and p.suffix in {".js", ".html", ".txt"}]
    assert files, "No built files found in portable/web/out"
    for path in files:
        content = path.read_text(encoding="utf-8", errors="ignore")
        for pattern in SECRET_PATTERNS:
            assert not pattern.search(content), f"Secret pattern {pattern.pattern} matched in {path}"
        for env_name in SERVER_ENV_NAMES:
            assert env_name not in content, f"Server env var {env_name} found in {path}"
