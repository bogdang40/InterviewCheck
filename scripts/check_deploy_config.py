#!/usr/bin/env python3
"""Validate InterviewCheck deployment configuration and optional production env flags."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from ipaddress import ip_address
import json
import os
from pathlib import Path
import re
import sys
from typing import Mapping
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
LOOPBACK_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})


@dataclass(frozen=True)
class CheckResult:
    id: str
    file: str
    ok: bool
    detail: str


def _check(results: list[CheckResult], cid: str, rel_file: str, ok: bool, detail: str) -> None:
    results.append(CheckResult(id=cid, file=rel_file, ok=bool(ok), detail=detail))


def _read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8") if path.is_file() else None
    except OSError:
        return None


def validate_caddyfile(root: Path, results: list[CheckResult]) -> None:
    rel = "deploy/Caddyfile"
    text = _read_text(root / rel)
    if text is None:
        _check(results, "caddyfile.exists", rel, False, "deploy/Caddyfile is missing.")
        return
    checks = [
        ("caddyfile.max_size", bool(re.search(r"\bmax_size\s+26MB\b", text)), "Requires max_size 26MB request_body limit."),
        ("caddyfile.client_ip_header", "header_up X-InterviewCheck-Client-IP" in text, "Requires header_up X-InterviewCheck-Client-IP overwrite."),
        ("caddyfile.strip_server", bool(re.search(r"^\s*-Server\b", text, re.MULTILINE)), "Requires -Server header removal."),
        ("caddyfile.x_frame_options", 'X-Frame-Options "DENY"' in text, 'Requires X-Frame-Options "DENY".'),
        ("caddyfile.nosniff", 'X-Content-Type-Options "nosniff"' in text, 'Requires X-Content-Type-Options "nosniff".'),
        ("caddyfile.hsts", "Strict-Transport-Security" in text, "Requires Strict-Transport-Security header."),
        ("caddyfile.csp_frame_ancestors", "frame-ancestors 'none'" in text, "Requires frame-ancestors 'none' CSP directive."),
        ("caddyfile.loopback_upstream", "reverse_proxy 127.0.0.1:3000" in text, "Requires reverse_proxy 127.0.0.1:3000 loopback target."),
    ]
    for cid, ok, detail in checks:
        _check(results, cid, rel, ok, detail)


def validate_compose(root: Path, results: list[CheckResult]) -> None:
    rel = "deploy/compose.yml"
    text = _read_text(root / rel)
    if text is None:
        _check(results, "compose.exists", rel, False, "deploy/compose.yml is missing.")
        return
    checks = [
        ("compose.network_mode_host", bool(re.search(r"^\s*network_mode:\s*host\b", text, re.MULTILINE)), "Requires network_mode: host."),
        ("compose.app_env", bool(re.search(r"env_file:\s*\[?\s*app\.env", text)), "Requires env_file referencing app.env."),
        ("compose.init", bool(re.search(r"^\s*init:\s*true\b", text, re.MULTILINE)), "Requires init: true for app container."),
        ("compose.data_volume", "./data:/data" in text, "Requires ./data:/data persistent volume."),
        ("compose.caddyfile_ro", "./Caddyfile:/etc/caddy/Caddyfile:ro" in text, "Requires read-only Caddyfile mount."),
    ]
    for cid, ok, detail in checks:
        _check(results, cid, rel, ok, detail)


def validate_dockerfile(root: Path, results: list[CheckResult]) -> None:
    rel = "deploy/Dockerfile"
    text = _read_text(root / rel)
    if text is None:
        _check(results, "dockerfile.exists", rel, False, "deploy/Dockerfile is missing.")
        return
    checks = [
        ("dockerfile.user_app", bool(re.search(r"^\s*USER\s+app\b", text, re.MULTILINE)), "Requires non-root USER app."),
        ("dockerfile.useradd", bool(re.search(r"\buseradd\b.*\bapp\b", text)), "Requires explicit app user creation."),
        ("dockerfile.healthcheck", bool(re.search(r"^\s*HEALTHCHECK\b", text, re.MULTILINE)), "Requires HEALTHCHECK instruction."),
        ("dockerfile.health_url", "/api/readyz" in text, "Requires the /api/readyz probe inside HEALTHCHECK."),
    ]
    for cid, ok, detail in checks:
        _check(results, cid, rel, ok, detail)


def validate_rollout(root: Path, results: list[CheckResult]) -> None:
    rel = "deploy/vm-rollout.sh"
    text = _read_text(root / rel)
    if text is None:
        _check(results, "rollout.exists", rel, False, "deploy/vm-rollout.sh is missing.")
        return
    checks = [
        ("rollout.strict_shell", "set -euo pipefail" in text, "Requires set -euo pipefail."),
        ("rollout.pre_deploy_backup", "backup.sh pre-deploy" in text, "Requires pre-deploy backup execution."),
        ("rollout.app_env_check", "app.env" in text, "Requires app.env presence check."),
        ("rollout.rollback", "rolling back" in text and "CURRENT" in text, "Requires automatic rollback on failed health check."),
        ("rollout.marker", "ROLLOUT_OK" in text, "Requires ROLLOUT_OK completion marker."),
    ]
    for cid, ok, detail in checks:
        _check(results, cid, rel, ok, detail)


def _valid_https_origin(value: str) -> bool:
    if not value:
        return False
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        return False
    host = (parsed.hostname or "").lower()
    if not host or host in LOOPBACK_HOSTS:
        return False
    try:
        if ip_address(host).is_loopback:
            return False
    except ValueError:
        pass
    return True


def validate_strict_prod_env(env: Mapping[str, str], results: list[CheckResult]) -> None:
    src = "env"
    origin = env.get("INTERVIEWCHECK_PUBLIC_ORIGIN", "").strip()
    _check(results, "prod.public_origin", src, _valid_https_origin(origin), "INTERVIEWCHECK_PUBLIC_ORIGIN must be an external https:// origin.")
    mode = env.get("INTERVIEWCHECK_ACCESS_MODE", "").strip().lower()
    _check(results, "prod.access_mode", src, mode in {"embedded", "remote"}, "INTERVIEWCHECK_ACCESS_MODE must be 'embedded' or 'remote'.")
    trust_ip = env.get("INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP", "").strip()
    _check(results, "prod.trust_proxy_client_ip", src, trust_ip == "1", "INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP must equal '1' behind Caddy.")
    if mode == "remote":
        access_url = env.get("INTERVIEWCHECK_ACCESS_URL", "").strip()
        _check(results, "prod.access_url", src, _valid_https_origin(access_url), "INTERVIEWCHECK_ACCESS_URL must be https:// when access mode is remote.")
    else:
        has_admin = bool(env.get("ADMIN_EMAILS", "").strip() or env.get("INTERVIEWCHECK_OPERATOR_EMAIL", "").strip())
        _check(results, "prod.operator_or_admin_email", src, has_admin, "Set ADMIN_EMAILS or INTERVIEWCHECK_OPERATOR_EMAIL in production.")
        has_secret = bool(env.get("INTERVIEWCHECK_SIGNUP_SECRET", "").strip() or env.get("ADMIN_BOOTSTRAP_SECRET", "").strip())
        _check(results, "prod.bootstrap_or_signup_secret", src, has_secret, "Set INTERVIEWCHECK_SIGNUP_SECRET or ADMIN_BOOTSTRAP_SECRET in production.")


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, val = stripped.split("=", 1)
        values[key.strip()] = val.strip().strip('"').strip("'")
    return values


def run_checks(root: Path, *, strict_prod: bool = False, env: Mapping[str, str] | None = None) -> dict[str, object]:
    results: list[CheckResult] = []
    validate_caddyfile(root, results)
    validate_compose(root, results)
    validate_dockerfile(root, results)
    validate_rollout(root, results)
    if strict_prod:
        validate_strict_prod_env(os.environ if env is None else env, results)
    errors = [f"{r.file}: {r.id}: {r.detail}" for r in results if not r.ok]
    return {
        "ok": not errors,
        "strict_prod": strict_prod,
        "checks": [asdict(r) for r in results],
        "errors": errors,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate InterviewCheck deployment configuration.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON report.")
    parser.add_argument("--strict-prod", action="store_true", help="Validate production environment flags too.")
    parser.add_argument("--root", type=Path, default=ROOT, help="Repository root containing deploy/.")
    parser.add_argument("--env-file", type=Path, default=None, help="Optional env file for --strict-prod checks.")
    args = parser.parse_args(argv)
    env_map: Mapping[str, str] | None = None
    if args.env_file is not None:
        if not args.env_file.is_file():
            payload = {"ok": False, "strict_prod": args.strict_prod, "checks": [], "errors": [f"Missing env file: {args.env_file}"]}
            print(json.dumps(payload, indent=2) if args.json else payload["errors"][0])
            return 1
        env_map = parse_env_file(args.env_file)
    report = run_checks(args.root, strict_prod=args.strict_prod, env=env_map)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for item in report["checks"]:
            status = "PASS" if item["ok"] else "FAIL"
            print(f"[{status}] {item['id']}: {item['detail']}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
