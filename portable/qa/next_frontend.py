"""Run the installed Next.js command with a test-only loopback upstream."""
from contextlib import contextmanager
import os
from pathlib import Path
import signal
import socket
import subprocess
import time
from urllib.error import URLError
from urllib.request import urlopen


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


@contextmanager
def serve_next(web, mode, api_port, log_path):
    if mode == "start" and not (web / ".next-server/BUILD_ID").is_file():
        raise RuntimeError("Build the production Next.js app before testing --frontend=start.")
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    environment = {**os.environ, "INTERVIEWCHECK_API_PORT": str(api_port),
                   "INTERVIEWCHECK_WEB_PORT": str(port), "NEXT_TELEMETRY_DISABLED": "1"}
    cli = web / "node_modules/next/dist/bin/next"
    command = ["node", str(cli), mode, "--hostname", "127.0.0.1", "--port", str(port)]
    if mode == "dev":
        command.append("--webpack")
    options = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=web, env=environment, stdout=log, stderr=subprocess.STDOUT, **options)
        try:
            deadline = time.monotonic() + 90
            while True:
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(f"Next.js {mode} did not start.\n" + log_path.read_text(errors="replace")[-1800:])
                try:
                    with urlopen(base, timeout=25) as response:
                        if response.status == 200:
                            break
                except (URLError, TimeoutError):
                    time.sleep(0.15)
            yield base, port
        finally:
            if process.poll() is None:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                   check=False, stdout=subprocess.DEVNULL)
                else:
                    os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=15)
