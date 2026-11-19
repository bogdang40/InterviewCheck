#!/usr/bin/env python3
"""Aggregate production readiness checks for InterviewCheck."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from html.parser import HTMLParser
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
    "portable/api", "portable/web/app", "portable/web/components", "portable/web/lib",
    "portable/tests", "portable/qa", "server/src", "server/test", "scripts", "docs",
)
ROOT_TEXT_FILES = (
    "README.md", "RELEASE_AUDIT.md", "TEST_READY.md", "TEST_INFRA.md", "PLAN.md",
    "portable/web/inject-csp.mjs", "portable/web-runtime.mjs", "portable/web/next.config.ts",
)
SKIP_PARTS = frozenset({"node_modules", ".venv", "__pycache__", ".next", "out", ".git", ".build"})
TEXT_EXTENSIONS = frozenset({
    ".py", ".ts", ".tsx", ".js", ".mjs", ".css", ".sh", ".md", ".html", ".swift", ".metal", ".yml", ".yaml", ".json", ".txt",
})
FORBIDDEN_DASHES = ("\u2014", "\u2013")
MAX_ROUTE_ESM_BYTES = 600 * 1024  # 614,400 bytes
FORBIDDEN_BUNDLE_TOKENS = ("WebGLRenderer", "framer-motion", "MotionConfig", "OrthographicCamera")
SECRET_BUNDLE_MARKERS = (
    "ADMIN_BOOTSTRAP_SECRET", "INTERVIEWCHECK_MODEL_SECRET_KEY", "encrypted_api_key", "encrypted_signing_secret",
)


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
    check_id: str, cmd: list[str], *, root: Path, parse_json: bool = False, extra_env: dict[str, str] | None = None
) -> AuditCheck:
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, cwd=str(root), env=_subprocess_env(root, extra_env), capture_output=True, text=True, check=False)
    elapsed_ms = int((time.perf_counter() - t0) * 1000)
    stdout, stderr = (proc.stdout or "").strip(), (proc.stderr or "").strip()
    data: dict[str, Any] = {}
    if parse_json and stdout:
        try:
            parsed = json.loads(stdout)
            if isinstance(parsed, dict):
                data = parsed
        except ValueError:
            data = {"raw_stdout": stdout[:500]}
    ok = proc.returncode == 0 and (data.get("ok", True) is True if parse_json and data and "ok" in data else True)
    detail = stdout if not parse_json else (data.get("error") or "; ".join(data.get("errors", [])) or f"ok={ok}")
    if not detail:
        detail = stderr or f"Exited with code {proc.returncode}"
    elif stderr and not ok and stderr not in detail:
        detail = f"{detail} | {stderr}"
    return AuditCheck(id=check_id, ok=ok, exit_code=proc.returncode, duration_ms=elapsed_ms, detail=detail, data=data)


def _iter_files(root: Path, dirs: tuple[str, ...], extensions: frozenset[str]) -> list[Path]:
    seen: set[Path] = set()
    files: list[Path] = []
    for rel_dir in dirs:
        base = root / rel_dir
        if base.is_dir():
            for path in sorted(base.rglob("*")):
                if path.is_file() and not _should_skip(path) and path.suffix in extensions and path not in seen:
                    seen.add(path)
                    files.append(path)
    for rel_file in ROOT_TEXT_FILES:
        path = root / rel_file
        if path.is_file() and path.suffix in extensions and path not in seen:
            seen.add(path)
            files.append(path)
    return files


def check_web_and_docs_line_limit(root: Path, *, max_lines: int = 400) -> AuditCheck:
    t0 = time.perf_counter()
    files = _iter_files(root, WEB_AND_DOCS_DIRS, WEB_DOCS_EXTENSIONS)
    violations = [
        f"{p.relative_to(root).as_posix()}: {n} lines"
        for p in files
        if (n := len(p.read_text(encoding="utf-8", errors="ignore").splitlines())) > max_lines
    ]
    ok = not violations
    detail = f"Checked {len(files)} web/docs files, all at most {max_lines} lines." if ok else "; ".join(violations)
    return AuditCheck(
        id="source_size_web_docs", ok=ok, exit_code=0 if ok else 1,
        duration_ms=int((time.perf_counter() - t0) * 1000), detail=detail,
        data={"checked": len(files), "max_lines": max_lines, "violations": violations},
    )


def check_zero_dashes(root: Path) -> AuditCheck:
    t0 = time.perf_counter()
    files = _iter_files(root, FIRST_PARTY_DIRS, TEXT_EXTENSIONS)
    offenders = [
        p.relative_to(root).as_posix()
        for p in files
        if any(ch in p.read_text(encoding="utf-8", errors="ignore") for ch in FORBIDDEN_DASHES)
    ]
    ok = not offenders
    detail = (
        f"Scanned {len(files)} first-party files with zero em/en dashes."
        if ok else f"Found em/en dashes in {len(offenders)} files: {', '.join(offenders[:10])}"
    )
    return AuditCheck(
        id="zero_em_en_dashes", ok=ok, exit_code=0 if ok else 1,
        duration_ms=int((time.perf_counter() - t0) * 1000), detail=detail,
        data={"checked": len(files), "offenders": offenders},
    )


class _ScriptSrcParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.esm_srcs: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "script":
            return
        attr_map = {k.lower(): v for k, v in attrs}
        src = attr_map.get("src")
        if src and "nomodule" not in attr_map:
            self.esm_srcs.append(src)


def check_web_bundle_budget(root: Path) -> AuditCheck:
    t0 = time.perf_counter()
    out_dir = (Path(root) / "portable" / "web" / "out").resolve()
    chunks_dir = out_dir / "_next" / "static" / "chunks"
    if not (out_dir / "index.html").is_file() or not chunks_dir.is_dir():
        return AuditCheck(
            id="web_bundle_budget", ok=False, exit_code=1, duration_ms=int((time.perf_counter() - t0) * 1000),
            detail=f"Missing built static bundle under {out_dir}",
            data={"out_dir": str(out_dir), "violations": ["missing_out_dir"]},
        )

    html_files = sorted(out_dir.rglob("*.html"))
    chunks = sorted(chunks_dir.rglob("*.js"))
    violations: list[str] = [] if chunks else ["No JS chunks found under _next/static/chunks"]
    max_route_bytes = 0
    for html_path in html_files:
        rel_html = html_path.relative_to(out_dir).as_posix()
        parser = _ScriptSrcParser()
        parser.feed(html_path.read_text(encoding="utf-8", errors="ignore"))
        if not parser.esm_srcs:
            violations.append(f"{rel_html}: no active ESM scripts found")
            continue
        route_bytes = 0
        for src in parser.esm_srcs:
            target = (out_dir / src.split("?", 1)[0].lstrip("/")).resolve()
            if not target.is_relative_to(out_dir) or not target.is_file():
                violations.append(f"{rel_html}: missing script {src}")
            else:
                route_bytes += target.stat().st_size
        max_route_bytes = max(max_route_bytes, route_bytes)
        if route_bytes >= MAX_ROUTE_ESM_BYTES:
            violations.append(f"{rel_html}: {route_bytes} B >= {MAX_ROUTE_ESM_BYTES} B")

    forbidden = FORBIDDEN_BUNDLE_TOKENS + SECRET_BUNDLE_MARKERS
    for chunk in chunks:
        text = chunk.read_text(encoding="utf-8", errors="ignore")
        rel_chunk = chunk.relative_to(out_dir).as_posix()
        for token in forbidden:
            if token in text:
                violations.append(f"{rel_chunk}: forbidden token {token}")

    ok = not violations
    detail = (
        f"Checked {len(html_files)} routes and {len(chunks)} chunks; max route JS {max_route_bytes} B (< {MAX_ROUTE_ESM_BYTES} B)."
        if ok else "; ".join(violations[:8])
    )
    return AuditCheck(
        id="web_bundle_budget", ok=ok, exit_code=0 if ok else 1,
        duration_ms=int((time.perf_counter() - t0) * 1000), detail=detail,
        data={
            "routes_checked": len(html_files), "chunks_checked": len(chunks),
            "max_route_bytes": max_route_bytes, "max_allowed_bytes": MAX_ROUTE_ESM_BYTES, "violations": violations,
        },
    )


def run_audit(
    root: Path, *, with_dr: bool = False, strict_prod: bool = False, with_bundle: bool = False
) -> dict[str, Any]:
    root = Path(root).resolve()
    deploy_cmd = [sys.executable, str(root / "scripts" / "check_deploy_config.py"), "--json", "--root", str(root)]
    if strict_prod:
        deploy_cmd.append("--strict-prod")
    checks: list[AuditCheck] = [
        _run_subprocess_check("source_size_backend", [sys.executable, str(root / "scripts" / "check-source-size.py")], root=root),
        check_web_and_docs_line_limit(root),
        check_zero_dashes(root),
        _run_subprocess_check("deploy_config", deploy_cmd, root=root, parse_json=True),
    ]
    with tempfile.TemporaryDirectory(prefix="ic-prod-audit-edge-") as tmp_dir:
        tmp_path = Path(tmp_dir)
        edge_env = {"INTERVIEWCHECK_DB": str(tmp_path / "review.sqlite3"), "INTERVIEWCHECK_ACCESS_DB": str(tmp_path / "access.sqlite3")}
        edge_cmd = [sys.executable, str(root / "scripts" / "verify_edge_security.py"), "--asgi", "--json"]
        checks.append(_run_subprocess_check("edge_security_asgi", edge_cmd, root=root, parse_json=True, extra_env=edge_env))

    if with_dr:
        checks.append(_run_subprocess_check("dr_drill", [sys.executable, str(root / "scripts" / "dr_drill.py"), "--json"], root=root, parse_json=True))
    if with_bundle:
        checks.append(check_web_bundle_budget(root))

    errors = [f"{c.id}: {c.detail}" for c in checks if not c.ok]
    return {
        "ok": not errors, "root": str(root), "python": sys.executable,
        "with_dr": with_dr, "with_bundle": with_bundle, "checks": [asdict(c) for c in checks], "errors": errors,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run aggregated InterviewCheck production audit checks.")
    parser.add_argument("--json", action="store_true", dest="as_json", help="Emit structured JSON report.")
    parser.add_argument("--with-dr", action="store_true", help="Include scripts/dr_drill.py verification.")
    parser.add_argument("--with-bundle", action="store_true", help="Validate built portable/web/out/ bundle size and tokens.")
    parser.add_argument("--strict-prod", action="store_true", help="Pass --strict-prod to check_deploy_config.py.")
    parser.add_argument("--root", type=Path, default=ROOT, help="Repository root directory.")
    args = parser.parse_args(argv)
    report = run_audit(args.root, with_dr=args.with_dr, strict_prod=args.strict_prod, with_bundle=args.with_bundle)
    if args.as_json:
        print(json.dumps(report, indent=2))
    else:
        for item in report["checks"]:
            print(f"[{'PASS' if item['ok'] else 'FAIL'}] {item['id']} ({item['duration_ms']}ms): {item['detail']}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
