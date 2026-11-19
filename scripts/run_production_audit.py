#!/usr/bin/env python3
"""Aggregate production readiness checks for InterviewCheck."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
WEB_AND_DOCS_DIRS = ("portable/web/app", "portable/web/components", "portable/web/lib", "docs")
WEB_DOCS_EXTENSIONS = frozenset({".ts", ".tsx", ".js", ".mjs", ".css", ".md", ".html"})
FIRST_PARTY_DIRS = (
    "portable/api",
    "portable/web/app",
    "portable/web/components",
    "portable/web/lib",
    "portable/tests",
    "portable/qa",
    "server/src",
    "server/test",
    "scripts",
    "docs",
)
SKIP_PARTS = frozenset({"node_modules", ".venv", "__pycache__", ".next", "out", ".git", ".build"})
TEXT_EXTENSIONS = frozenset({
    ".py", ".ts", ".tsx", ".js", ".mjs", ".css", ".sh", ".md", ".html", ".swift", ".metal", ".yml", ".yaml", ".json", ".txt",
})
FORBIDDEN_DASHES = ("\u2014", "\u2013")


@dataclass(frozen=True)
class AuditCheck:
    id: str
    ok: bool
    exit_code: int
    duration_ms: int
    detail: str
    data: dict[str, Any]


def _should_skip(path: Path) -> bool:
    return any(part in SKIP_PARTS for part in path.parts)


def _subprocess_env(root: Path, extra_env: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ)
    portable_dir = str(root / "portable")
    current_pp = env.get("PYTHONPATH", "")
    pp_parts = [p for p in current_pp.split(os.pathsep) if p] if current_pp else []
    if portable_dir not in pp_parts:
        pp_parts.insert(0, portable_dir)
    env["PYTHONPATH"] = os.pathsep.join(pp_parts)
    if extra_env:
        env.update(extra_env)
    return env


def _run_subprocess_check(
    check_id: str,
    cmd: list[str],
    *,
    root: Path,
    parse_json: bool = False,
    extra_env: dict[str, str] | None = None,
) -> AuditCheck:
    t0 = time.perf_counter()
    proc = subprocess.run(
        cmd,
        cwd=str(root),
        env=_subprocess_env(root, extra_env),
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed_ms = int((time.perf_counter() - t0) * 1000)
    stdout = (proc.stdout or "").strip()
    stderr = (proc.stderr or "").strip()
    data: dict[str, Any] = {}
    if parse_json and stdout:
        try:
            parsed = json.loads(stdout)
            if isinstance(parsed, dict):
                data = parsed
        except ValueError:
            data = {"raw_stdout": stdout[:500]}
    ok = proc.returncode == 0 and (data.get("ok", True) is True if parse_json and data else True)
    if parse_json and data and "ok" not in data:
        ok = proc.returncode == 0
    detail = stdout if not parse_json else (data.get("error") or "; ".join(data.get("errors", [])) or f"ok={ok}")
    if not detail:
        detail = stderr or f"Exited with code {proc.returncode}"
    elif stderr and not ok and stderr not in detail:
        detail = f"{detail} | {stderr}"
    return AuditCheck(id=check_id, ok=ok, exit_code=proc.returncode, duration_ms=elapsed_ms, detail=detail, data=data)


def check_web_and_docs_line_limit(root: Path, *, max_lines: int = 400) -> AuditCheck:
    t0 = time.perf_counter()
    checked = 0
    violations: list[str] = []
    for rel_dir in WEB_AND_DOCS_DIRS:
        base = root / rel_dir
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file() or _should_skip(path) or path.suffix not in WEB_DOCS_EXTENSIONS:
                continue
            count = len(path.read_text(encoding="utf-8", errors="ignore").splitlines())
            checked += 1
            if count > max_lines:
                violations.append(f"{path.relative_to(root).as_posix()}: {count} lines")
    ok = not violations
    detail = f"Checked {checked} web/docs files, all at most {max_lines} lines." if ok else "; ".join(violations)
    return AuditCheck(
        id="source_size_web_docs",
        ok=ok,
        exit_code=0 if ok else 1,
        duration_ms=int((time.perf_counter() - t0) * 1000),
        detail=detail,
        data={"checked": checked, "max_lines": max_lines, "violations": violations},
    )


def check_zero_dashes(root: Path) -> AuditCheck:
    t0 = time.perf_counter()
    checked = 0
    offenders: list[str] = []
    for rel_dir in FIRST_PARTY_DIRS:
        base = root / rel_dir
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file() or _should_skip(path) or path.suffix not in TEXT_EXTENSIONS:
                continue
            checked += 1
            text = path.read_text(encoding="utf-8", errors="ignore")
            if any(ch in text for ch in FORBIDDEN_DASHES):
                offenders.append(path.relative_to(root).as_posix())
    ok = not offenders
    detail = f"Scanned {checked} first-party files with zero em/en dashes." if ok else f"Found em/en dashes in {len(offenders)} files: {', '.join(offenders[:10])}"
    return AuditCheck(
        id="zero_em_en_dashes",
        ok=ok,
        exit_code=0 if ok else 1,
        duration_ms=int((time.perf_counter() - t0) * 1000),
        detail=detail,
        data={"checked": checked, "offenders": offenders},
    )


def run_audit(root: Path, *, with_dr: bool = False, strict_prod: bool = False) -> dict[str, Any]:
    root = Path(root).resolve()
    checks: list[AuditCheck] = []
    checks.append(
        _run_subprocess_check("source_size_backend", [sys.executable, str(root / "scripts" / "check-source-size.py")], root=root)
    )
    checks.append(check_web_and_docs_line_limit(root))
    checks.append(check_zero_dashes(root))

    deploy_cmd = [sys.executable, str(root / "scripts" / "check_deploy_config.py"), "--json", "--root", str(root)]
    if strict_prod:
        deploy_cmd.append("--strict-prod")
    checks.append(_run_subprocess_check("deploy_config", deploy_cmd, root=root, parse_json=True))

    with tempfile.TemporaryDirectory(prefix="ic-prod-audit-edge-") as tmp_dir:
        tmp_path = Path(tmp_dir)
        edge_env = {
            "INTERVIEWCHECK_DB": str(tmp_path / "review.sqlite3"),
            "INTERVIEWCHECK_ACCESS_DB": str(tmp_path / "access.sqlite3"),
        }
        checks.append(
            _run_subprocess_check(
                "edge_security_asgi",
                [sys.executable, str(root / "scripts" / "verify_edge_security.py"), "--asgi", "--json"],
                root=root,
                parse_json=True,
                extra_env=edge_env,
            )
        )

    if with_dr:
        checks.append(
            _run_subprocess_check(
                "dr_drill",
                [sys.executable, str(root / "scripts" / "dr_drill.py"), "--json"],
                root=root,
                parse_json=True,
            )
        )

    errors = [f"{c.id}: {c.detail}" for c in checks if not c.ok]
    return {
        "ok": not errors,
        "root": str(root),
        "python": sys.executable,
        "with_dr": with_dr,
        "checks": [asdict(c) for c in checks],
        "errors": errors,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run aggregated InterviewCheck production audit checks.")
    parser.add_argument("--json", action="store_true", dest="as_json", help="Emit structured JSON report.")
    parser.add_argument("--with-dr", action="store_true", help="Include scripts/dr_drill.py verification.")
    parser.add_argument("--strict-prod", action="store_true", help="Pass --strict-prod to check_deploy_config.py.")
    parser.add_argument("--root", type=Path, default=ROOT, help="Repository root directory.")
    args = parser.parse_args(argv)

    report = run_audit(args.root, with_dr=args.with_dr, strict_prod=args.strict_prod)
    if args.as_json:
        print(json.dumps(report, indent=2))
    else:
        for item in report["checks"]:
            status = "PASS" if item["ok"] else "FAIL"
            print(f"[{status}] {item['id']} ({item['duration_ms']}ms): {item['detail']}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
