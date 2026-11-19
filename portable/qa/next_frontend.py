"""Run the installed Next.js command with a test-only loopback upstream."""
from contextlib import contextmanager
from http.client import HTTPException
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import time
from urllib.error import URLError
from urllib.request import urlopen

STARTUP_RETRY_ERRORS = (URLError, HTTPException, TimeoutError, ConnectionError)


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def can_bind(port):
    try:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", port))
            return True
    except OSError:
        return False


def manifest_api_port(dist_dir):
    manifest_file = Path(dist_dir) / "routes-manifest.json"
    if not manifest_file.is_file():
        return None
    try:
        data = json.loads(manifest_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    rewrites = data.get("rewrites")
    if isinstance(rewrites, dict):
        routes = [rule for group in rewrites.values() if isinstance(group, list) for rule in group]
    elif isinstance(rewrites, list):
        routes = rewrites
    else:
        return None
    prefix = "http://127.0.0.1:"
    suffix = "/api/:path*"
    for rule in routes:
        if not isinstance(rule, dict):
            continue
        destination = rule.get("destination") or ""
        if rule.get("source") == "/api/:path*" and destination.startswith(prefix) and destination.endswith(suffix):
            port_text = destination[len(prefix):-len(suffix)]
            if port_text.isdigit():
                return int(port_text)
    return None


def wait_for_http_ready(url, process, log_path, mode, timeout=90, opener=urlopen, sleep=time.sleep):
    deadline = time.monotonic() + timeout
    while True:
        if process.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError(f"Next.js {mode} did not start.\n" + log_path.read_text(errors="replace")[-1800:])
        try:
            with opener(url, timeout=25) as response:
                if response.status == 200:
                    return
        except STARTUP_RETRY_ERRORS:
            pass
        sleep(0.15)


@contextmanager
def serve_next(web, mode, api_port, log_path):
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    environment = {**os.environ, "INTERVIEWCHECK_API_PORT": str(api_port),
                   "INTERVIEWCHECK_WEB_PORT": str(port), "NEXT_TELEMETRY_DISABLED": "1"}
    environment.pop("INTERVIEWCHECK_NEXT_DIST_DIR", None)
    cli = web / "node_modules/next/dist/bin/next"
    command = ["node", str(cli), mode, "--hostname", "127.0.0.1", "--port", str(port)]
    if mode == "dev":
        command.append("--webpack")
    options = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
    isolated_path = None
    try:
        if mode == "start":
            default_dist = web / ".next-server"
            if not ((default_dist / "BUILD_ID").is_file() and manifest_api_port(default_dist) == api_port):
                isolated_dist = f".next/qa-{os.getpid()}"
                isolated_path = web / isolated_dist
                shutil.rmtree(isolated_path, ignore_errors=True)
                environment["INTERVIEWCHECK_NEXT_DIST_DIR"] = isolated_dist
                build = subprocess.run(
                    ["node", str(cli), "build", "--webpack"],
                    cwd=web,
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                if build.returncode != 0:
                    raise RuntimeError(f"Next.js build failed.\n{build.stdout[-1800:]}")
                inject = subprocess.run(
                    ["node", "inject-csp.mjs"],
                    cwd=web,
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                if inject.returncode != 0:
                    raise RuntimeError(f"CSP hash injection failed.\n{inject.stdout[-1800:]}")
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(command, cwd=web, env=environment, stdout=log, stderr=subprocess.STDOUT, **options)
            try:
                wait_for_http_ready(base, process, log_path, mode)
                yield base, port
            finally:
                if process.poll() is None:
                    if os.name == "nt":
                        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                       check=False, stdout=subprocess.DEVNULL)
                    else:
                        os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=15)
    finally:
        if isolated_path is not None:
            shutil.rmtree(isolated_path, ignore_errors=True)
