"""Start an extracted release without Node.js and check the served product."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from urllib.request import Request, urlopen
import zipfile


def stop_launcher(process):
    if process.poll() is not None:
        return
    if os.name == "nt":
        # Stop both the launcher and its uvicorn child on the Windows runner.
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, check=True)
    else:
        os.killpg(process.pid, signal.SIGINT)
    process.wait(timeout=15)


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
        env = {key: value for key, value in os.environ.items() if key.upper() not in
               {"PATH", "INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_DB"}}
        env.update(PATH=safe_path, PIP_DISABLE_PIP_VERSION_CHECK="1")

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
                    assert b"Interview workspace" in response.read()
                form = {"candidate": "Archive fixture", "role": "Engineer",
                        "policy": "Manual allowed.", "consent": True}
                request = Request(base + "/api/sessions", data=json.dumps(form).encode(), headers={
                    "Content-Type": "application/json", "X-InterviewCheck": "1",
                })
                with urlopen(request, timeout=5) as response:
                    assert json.load(response)["candidate"] == form["candidate"]
                assert (root / "data/review.sqlite3").exists()
            finally:
                stop_launcher(process)
    print("Release launched without Node.js. Health, browser entry and durable interview creation passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    smoke(parser.parse_args().archive)
