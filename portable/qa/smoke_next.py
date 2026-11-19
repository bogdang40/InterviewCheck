"""Exercise the normal npm development and production entry points with synthetic data."""
import argparse
from http.client import HTTPException
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
from tempfile import TemporaryDirectory
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from websockets.exceptions import ConnectionClosed, InvalidStatus
from websockets.sync.client import connect

from next_frontend import can_bind, free_port
from smoke_archive import stop_launcher

ROOT = Path(__file__).resolve().parents[2]
NPM = shutil.which("npm.cmd" if os.name == "nt" else "npm")
HEALTH_RETRY_ERRORS = (URLError, HTTPException, TimeoutError, ConnectionError)


def http(base, path, *, body=None, headers=None, timeout=20):
    req = Request(base + path, data=None if body is None else json.dumps(body).encode(), headers=headers or {})
    try:
        with urlopen(req, timeout=timeout) as response:
            return response.status, response.read()
    except HTTPError as error:
        return error.code, error.read()


def wait_for_health(base, process, log, opener=http, sleep=time.sleep):
    deadline = time.monotonic() + 70
    while time.monotonic() < deadline and process.poll() is None:
        try:
            status, body = opener(base, "/api/health")
            if status == 200 and json.loads(body).get("ok"):
                return
        except HEALTH_RETRY_ERRORS:
            pass
        sleep(0.25)
    raise RuntimeError(f"Service did not start.\n{log.read_text(errors='replace')[-2000:]}")


def resolve_smoke_ports(env=None):
    env = os.environ if env is None else env
    explicit_web = env.get("INTERVIEWCHECK_WEB_PORT")
    if explicit_web:
        web_port = int(explicit_web)
        with socket.socket() as check:
            check.bind(("127.0.0.1", web_port))
    else:
        web_port = 3000 if can_bind(3000) else free_port()

    explicit_api = env.get("INTERVIEWCHECK_API_PORT")
    if explicit_api:
        api_port = int(explicit_api)
        with socket.socket() as check:
            check.bind(("127.0.0.1", api_port))
    else:
        api_port = 8000 if can_bind(8000) else free_port()
        while api_port == web_port:
            api_port = free_port()
    return web_port, api_port


def verify(base):
    origin = {"Origin": base, "Content-Type": "application/json", "X-InterviewCheck": "1"}
    assert http(base, "/", timeout=60)[0] == 200
    payload = {"candidate": "Runtime fixture", "role": "Developer", "policy": "Notes permitted.", "consent": True}
    status, body = http(base, "/api/sessions", body=payload, headers=origin)
    assert status == 201, (status, body)
    assert json.loads(body)["candidate"] == payload["candidate"]
    reject, _ = http(base, "/api/sessions", body=payload, headers={**origin, "Origin": "https://foreign.invalid"})
    assert reject == 403
    assert http(base, "/api/sessions", headers={"Host": "foreign.invalid"})[0] in (400, 403)
    address = base.replace("http:", "ws:") + "/api/integrations/live"
    with connect(address, origin=base, open_timeout=8) as ws:
        # Close before the transfer acknowledgement. No provider connection opens.
        ws.send("cancel")
        try:
            ws.recv()
        except ConnectionClosed:
            if ws.close_code != 1008:
                raise
        assert ws.close_code == 1008
    try:
        with connect(address, origin="https://foreign.invalid", open_timeout=8):
            raise AssertionError("WebSocket accepted an unrelated origin")
    except InvalidStatus as error:
        assert error.response.status_code == 403


def smoke(modes):
    if not NPM:
        raise SystemExit("Install npm before running this smoke test.")
    web_port, api_port = resolve_smoke_ports()
    web_dir = ROOT / "portable/web"
    dist_dir = web_dir / ".next-server"
    backup_dir = None
    if "start" in modes and api_port != 8000 and dist_dir.exists():
        (web_dir / ".next").mkdir(parents=True, exist_ok=True)
        backup_dir = web_dir / ".next" / f"smoke-backup-{os.getpid()}"
        shutil.rmtree(backup_dir, ignore_errors=True)
        dist_dir.rename(backup_dir)
    try:
        with TemporaryDirectory(prefix="interviewcheck-next-") as temp:
            work = Path(temp)
            env = {key: value for key, value in os.environ.items() if not key.startswith("INTERVIEWCHECK_")}
            env.update(INTERVIEWCHECK_WEB_PORT=str(web_port), INTERVIEWCHECK_API_PORT=str(api_port),
                       INTERVIEWCHECK_DB=str(work / "scratch.sqlite"), DEEPGRAM_API_KEY="offline-handshake-fixture")
            options = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
            for mode in modes:
                if mode == "start":
                    subprocess.run([NPM, "run", "build"], cwd=ROOT, env=env, check=True)
                logfile = work / (mode + ".log")
                with logfile.open("w") as out:
                    child = subprocess.Popen([NPM, "run", mode], cwd=ROOT, env=env, stdout=out, stderr=subprocess.STDOUT, **options)
                    try:
                        base = f"http://localhost:{web_port}"
                        wait_for_health(base, child, logfile)
                        verify(base)
                    finally:
                        stop_launcher(child, (web_port, api_port))
                print(f"npm run {mode} passed HTTP, WebSocket and shutdown checks.", flush=True)
    finally:
        if backup_dir is not None and backup_dir.exists():
            shutil.rmtree(dist_dir, ignore_errors=True)
            backup_dir.rename(dist_dir)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("modes", nargs="*", metavar="MODE", help="dev or start; default is both")
    args = parser.parse_args()
    if any(mode not in {"dev", "start"} for mode in args.modes):
        parser.error("Select dev and/or start.")
    smoke(args.modes or ["dev", "start"])
