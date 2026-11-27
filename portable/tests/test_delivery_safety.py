"""Static guards for the delivery path: Caddy headers, workflow pins and ordering, release contents, edge checks."""
import asyncio
import importlib.util
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import zipfile

import httpx
import pytest

ROOT = Path(__file__).resolve().parents[2]
APP_OWNED_HEADERS = {"content-security-policy", "referrer-policy", "x-content-type-options", "x-frame-options"}


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def caddy_header_operations(text: str) -> list[tuple[str, str, bool]]:
    """(field, operator, own directive) for every response header operation in the Caddyfile."""
    ops, block = [], False
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if block:
            if line == "}":
                block = False
            elif line:
                field = line.split()[0]
                ops.append((field.lstrip("+-?>").lower(), field[0] if field[0] in "+-?>" else "", False))
            continue
        words = line.split()
        if words[:1] == ["header"]:
            if words[-1] == "{":
                block = True
            elif len(words) > 1:
                ops.append((words[1].lstrip("+-?>").lower(), words[1][0] if words[1][0] in "+-?>" else "", True))
    return ops


def test_caddy_only_defaults_headers_the_app_sets():
    ops = caddy_header_operations((ROOT / "deploy/Caddyfile").read_text(encoding="utf-8"))
    fields = {field for field, _, _ in ops}
    assert {"strict-transport-security", "server"} <= fields and APP_OWNED_HEADERS <= fields
    for field, operator, own_directive in ops:
        if field in APP_OWNED_HEADERS:
            # "?" sets the value only when the app sent none; anything else would replace the app's CSP.
            assert operator == "?", f"Caddy sets {field} unconditionally"
            # Caddy applies a block's "?" fields only when all of them are absent, so each needs its own line.
            assert own_directive, f"{field} must be its own `header ?Field value` directive"
    assert ("server", "-", False) in ops


def test_caddyfile_parser_catches_overwrites():
    bad = '{$SITE_ADDRESS} {\n\theader {\n\t\tContent-Security-Policy "frame-ancestors \'none\'"\n\t\t-Server\n\t}\n}\n'
    assert ("content-security-policy", "", False) in caddy_header_operations(bad)


def test_workflows_pin_every_action_to_a_commit():
    for workflow in sorted((ROOT / ".github/workflows").glob("*.yml")):
        uses = re.findall(r"^\s*(?:-\s*)?uses:\s*(.+)$", workflow.read_text(encoding="utf-8"), re.MULTILINE)
        assert uses, workflow
        for ref in uses:
            assert re.fullmatch(r"[\w.-]+/[\w.-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+", ref.strip()), (workflow.name, ref)
    dependabot = (ROOT / ".github/dependabot.yml").read_text(encoding="utf-8")
    assert "package-ecosystem: github-actions" in dependabot and "interval: weekly" in dependabot


def test_deploy_order_pattern_matches_the_ci_trigger_paths():
    deploy = (ROOT / ".github/workflows/deploy.yml").read_text(encoding="utf-8")
    portable = (ROOT / ".github/workflows/portable.yml").read_text(encoding="utf-8")
    pattern = re.compile(re.search(r"CI_PATHS: '([^']+)'", deploy).group(1))
    paths = re.findall(r'"([^"]+)"', re.search(r"push:.*?paths: \[([^\]]+)\]", portable, re.DOTALL).group(1))
    assert paths
    for path in paths:
        sample = path.replace("**", "nested/file.txt")
        assert pattern.search(sample), f"{sample} runs CI but the deploy order check ignores it"
    for unrelated in ("docs/DEPLOY.md", "README.md", ".github/workflows/deploy.yml", "portable.yml", "xdeploy/a"):
        assert not pattern.search(unrelated), unrelated
    assert "if: steps.order.outputs.deploy == 'true'" in deploy


def test_release_packages_runtime_json_and_an_executable_launcher(tmp_path, monkeypatch):
    package_release = _load("package_release", ROOT / "portable/package_release.py")
    fake = tmp_path / "portable"
    for rel in ("api/main.py", "api/sample_cases.json", "requirements.txt", "run.py", "README.md", "WEB.md",
                "CORE.md", "CONNECTIONS.md", "VERIFICATION.md", "RECOVERY-REGISTER-TEMPLATE.md", "RECOVERY-REGISTER.md", "evaluate.py", "evaluation/cases.json",
                "web/out/index.html"):
        (fake / rel).parent.mkdir(parents=True, exist_ok=True)
        (fake / rel).write_text("{}" if rel.endswith(".json") else "fixture")
    monkeypatch.setattr(package_release, "ROOT", fake)
    target = tmp_path / "release.zip"
    package_release.package(target)
    with zipfile.ZipFile(target) as archive:
        names = set(archive.namelist())
        assert "InterviewCheck/RECOVERY-REGISTER-TEMPLATE.md" in names
        assert "InterviewCheck/RECOVERY-REGISTER.md" not in names
        assert "InterviewCheck/api/sample_cases.json" in names
        info = archive.getinfo("InterviewCheck/start.sh")
        assert stat.S_IMODE(info.external_attr >> 16) == 0o755 and info.create_system == 3
    assert (ROOT / "portable/api/sample_cases.json").is_file()


def _edge_transport(page_csp: str, referrer: str):
    app = {"x-content-type-options": "nosniff", "x-frame-options": "DENY", "referrer-policy": referrer,
           "permissions-policy": "camera=()", "strict-transport-security": "max-age=31536000", "via": "1.1 Caddy"}

    def handle(request: httpx.Request) -> httpx.Response:
        if request.headers["host"] != "site.test":
            return httpx.Response(200, headers={"server": "Caddy"})  # Caddy serves no other host name
        if request.method == "OPTIONS" or (request.method == "POST" and request.headers.get("x-interviewcheck") != "1"):
            return httpx.Response(403, headers=app)
        if request.method == "POST" and request.headers.get("origin"):
            return httpx.Response(403, headers=app)
        csp = page_csp if request.url.path == "/" else "default-src 'none'; frame-ancestors 'none'"
        return httpx.Response(200, headers={**app, "content-security-policy": csp}, json={"ok": True})

    return httpx.MockTransport(handle)


def _edge_report(page_csp: str, referrer: str = "no-referrer") -> dict:
    edge = _load("verify_edge_security", ROOT / "scripts/verify_edge_security.py")

    async def run():
        async with httpx.AsyncClient(transport=_edge_transport(page_csp, referrer), base_url="https://site.test") as client:
            return await edge.run_edge_checks(client, mode="edge", target="https://site.test", edge=True)

    return asyncio.run(run())


def test_edge_mode_accepts_proxy_answers_and_requires_the_app_csp():
    good = _edge_report("default-src 'self'; script-src 'self' 'sha256-x'; frame-ancestors 'none'")
    assert good["ok"] is True, good["errors"]
    overwritten = _edge_report("frame-ancestors 'none'", referrer="same-origin")
    failed = {error.split(":", 1)[0] for error in overwritten["errors"]}
    assert failed == {"edge_keeps_app_csp", "mandatory_security_headers"}


@pytest.mark.skipif(os.name == "nt", reason="CI runs deploy/edge-smoke.sh with Bash on Linux.")
def test_edge_smoke_runs_the_caddy_image_compose_pins():
    script = (ROOT / "deploy/edge-smoke.sh").read_text(encoding="utf-8")
    compose = (ROOT / "deploy/compose.yml").read_text(encoding="utf-8")
    pinned = re.search(r"^\s*image:\s*(caddy:\S+)", compose, re.MULTILINE).group(1)
    assert pinned.split(":", 1)[1] not in script, "edge-smoke.sh must read the Caddy tag from compose.yml"
    line = next(entry for entry in script.splitlines() if entry.startswith("CADDY=$("))
    out = subprocess.run(["bash", "-c", line + '\nprintf %s "$CADDY"'], cwd=ROOT, text=True, capture_output=True)
    assert out.returncode == 0 and out.stdout == pinned, out
    assert "deploy/edge-smoke.sh interviewcheck-web:new" in (ROOT / ".github/workflows/portable.yml").read_text()
