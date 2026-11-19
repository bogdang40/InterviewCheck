"""Build and run InterviewCheck on a single local workstation."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import venv

ROOT = Path(__file__).resolve().parent
WEB = ROOT / "web"
ENV = ROOT / ".venv"


def execute(arguments, directory=ROOT):
    env = {**os.environ, "NEXT_TELEMETRY_DISABLED": "1"}
    subprocess.run([str(value) for value in arguments], cwd=directory, check=True, env=env)


def fingerprint(files):
    digest = hashlib.sha256()
    for path in sorted(files):
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def needs_update(stamp, expected):
    return not stamp.exists() or stamp.read_text().strip() != expected


def setup_python(refresh):
    python = ENV / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    if not python.exists():
        venv.EnvBuilder(with_pip=True).create(ENV)
    stamp = ENV / ".interviewcheck-dependencies"
    required = fingerprint([ROOT / "requirements.txt"])
    if refresh or needs_update(stamp, required):
        execute([python, "-m", "pip", "install", "-r", ROOT / "requirements.txt"])
        stamp.write_text(required)
    return python


def setup_web_dependencies(refresh=False):
    npm = shutil.which("npm.cmd" if os.name == "nt" else "npm")
    if not npm:
        raise SystemExit("Install Node.js 22.13 or newer with npm to build the interface.")
    deps_stamp = WEB / "node_modules/.interviewcheck-dependencies"
    dep_hash = fingerprint([WEB / "package-lock.json"])
    if refresh or needs_update(deps_stamp, dep_hash):
        execute([npm, "ci", "--no-audit", "--no-fund"], WEB)
        deps_stamp.write_text(dep_hash)
    return npm


def setup_web(refresh):
    if not (WEB / "package.json").is_file() and (WEB / "out/index.html").is_file():
        if refresh:
            print("This distribution includes its production interface. Rebuild it from the source checkout.")
        return
    lock = WEB / "package-lock.json"
    sources = [WEB / "next.config.ts", WEB / "export.mjs", lock, WEB / "package.json", WEB / "postcss.config.mjs",
               *WEB.glob("tsconfig*.json")]
    for folder in ("app", "components", "lib", "public"):
        sources.extend(path for path in (WEB / folder).rglob("*") if path.is_file())
    stamp = WEB / "out/.interviewcheck-build"
    build_hash = fingerprint(sources)
    if not refresh and (WEB / "out/index.html").exists() and not needs_update(stamp, build_hash):
        return
    npm = setup_web_dependencies(refresh)
    execute([npm, "run", "export"], WEB)
    stamp.write_text(fingerprint(sources))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--rebuild", action="store_true", help="Reinstall dependencies and rebuild the interface.")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--prepare-web-runtime", action="store_true", help="Install dependencies for the Next.js server.")

    args = parser.parse_args()
    if sys.version_info < (3, 11):
        parser.error("Python 3.11 or newer is required.")
    if not 1 <= args.port <= 65535:
        parser.error("Select a port between 1 and 65535.")
    python = setup_python(args.rebuild)
    if args.prepare_web_runtime:
        setup_web_dependencies(args.rebuild)
        return
    setup_web(args.rebuild)
    if not args.build_only:
        print(f"Open http://127.0.0.1:{args.port} in your browser. Press Ctrl+C to stop.", flush=True)
        execute([python, "-m", "uvicorn", "api.main:app", "--host", "127.0.0.1",
                 "--port", str(args.port), "--no-access-log", "--timeout-keep-alive", "120"])


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)
