"""Start an extracted release without Node.js and check the served product."""
import argparse
import json
from http.cookiejar import CookieJar
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from urllib.error import HTTPError
from urllib.request import HTTPCookieProcessor, Request, build_opener, urlopen
import zipfile


def listening(port):
    with socket.socket() as client:
        return client.connect_ex(("127.0.0.1", port)) == 0


def stop_launcher(process, ports):
    kill_result = None
    if process.poll() is None:
        if os.name == "nt":
            # A child can exit while taskkill is walking the process tree.
            kill_result = subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                         stdout=subprocess.DEVNULL, check=False)
        else:
            os.killpg(process.pid, signal.SIGINT)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            if kill_result is not None:
                kill_result.check_returncode()
            raise

    deadline = time.monotonic() + 8
    while any(listening(port) for port in ports):
        if time.monotonic() >= deadline:
            if kill_result is not None:
                kill_result.check_returncode()
            raise AssertionError("A child service remained after shutdown.")
        time.sleep(0.1)


def smoke(archive):
    with TemporaryDirectory(prefix="InterviewCheck release ") as directory:
        destination = Path(directory)
        with zipfile.ZipFile(archive) as bundle:
            assert bundle.testzip() is None
            bundle.extractall(destination)
        root = destination / "InterviewCheck"
        assert not (root / "web/package.json").exists()
        assert not (root / "data").exists()
        safe_path = str(Path(os.environ["SystemRoot"]) / "System32") if os.name == "nt" else "/nonexistent"
        assert not shutil.which("node", path=safe_path)
        env = {key: value for key, value in os.environ.items()
               if not key.upper().startswith(("INTERVIEWCHECK_", "STRIPE_", "ADMIN_"))
               and key.upper() != "PATH"}
        env.update(PATH=safe_path, PIP_DISABLE_PIP_VERSION_CHECK="1", TRIAL_DAYS="3",
                   INTERVIEWCHECK_ACCESS_MODE="embedded", INTERVIEWCHECK_OPERATOR_EMAIL="release@example.invalid")

        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        args = [sys.executable, "run.py", "--port", str(port)]
        options = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
        log_path = destination / "launcher.log"
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(args, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, **options)
            try:
                base = f"http://127.0.0.1:{port}"
                deadline = time.monotonic() + 180
                while True:
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("Packaged app failed to start.\n" + log_path.read_text(errors="replace")[-2000:])
                    try:
                        with urlopen(base + "/api/health", timeout=2) as response:
                            assert json.load(response)["ok"] is True
                        break
                    except OSError:
                        time.sleep(0.25)
                with urlopen(base, timeout=5) as response:
                    assert response.headers.get_content_type() == "text/html"
                    entry = (root / "web" / "out" / "index.html").read_bytes()
                    assert entry and response.read() == entry, "Expected the packaged workspace entry page."
                try:
                    urlopen(base + "/api/sessions", timeout=5).close()
                except HTTPError as denied:
                    assert denied.code == 401
                else:
                    raise AssertionError("Embedded account mode allowed access before sign in.")
                browser = build_opener(HTTPCookieProcessor(CookieJar()))
                account = {"email": "release@example.invalid", "password": "Synthetic-release-fixture"}
                headers = {"Content-Type": "application/json", "X-InterviewCheck": "1"}
                signup = Request(base + "/api/integrations/access/signup", data=json.dumps(account).encode(), headers=headers)
                with browser.open(signup, timeout=8) as response:
                    assert json.load(response)["active"] is True
                form = {"candidate": "Archive fixture", "role": "Engineer",
                        "policy": "Manual allowed.", "consent": True}
                request = Request(base + "/api/sessions", data=json.dumps(form).encode(), headers=headers)
                with browser.open(request, timeout=5) as response:
                    assert json.load(response)["candidate"] == form["candidate"]
                assert (root / "data/review.sqlite3").exists()
                assert (root / "data/access.sqlite3").exists()
            finally:
                stop_launcher(process, (port,))
    print("Release launched without Node.js. Health, browser entry, embedded signup and durable interview creation passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    smoke(parser.parse_args().archive)
