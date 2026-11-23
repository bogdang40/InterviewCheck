"""Bundle the production interface and the portable FastAPI service."""
import argparse
import hashlib
from pathlib import Path
import stat
import time
import zipfile

ROOT = Path(__file__).resolve().parent


def package(target):
    export = ROOT / "web/out"
    if not (export / "index.html").is_file():
        raise SystemExit("Build the Next.js interface before packaging.")
    # An allowlist excludes credentials, virtual environments, caches and local records.
    # api/*.json holds data the service loads at run time, such as the public sample cases.
    files = [*sorted((ROOT / "api").glob("*.py")), *sorted((ROOT / "api").glob("*.json")),
             ROOT / "requirements.txt", ROOT / "run.py",
             ROOT / "README.md", ROOT / "WEB.md", ROOT / "CORE.md", ROOT / "CONNECTIONS.md", ROOT / "VERIFICATION.md",
             ROOT / "evaluate.py", ROOT / "evaluation/cases.json"]
    files.extend(p for p in sorted(export.rglob("*")) if p.is_file() and not p.name.startswith("."))
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            name = "InterviewCheck/" + path.relative_to(ROOT).as_posix()
            archive.write(path, name)
        archive.writestr("InterviewCheck/Start InterviewCheck.cmd", '@echo off\r\ncd /d "%~dp0"\r\npy -3 run.py\r\nif errorlevel 1 pause\r\n')
        launcher = zipfile.ZipInfo("InterviewCheck/start.sh", date_time=time.gmtime()[:6])
        launcher.compress_type = zipfile.ZIP_DEFLATED
        launcher.create_system = 3  # Unix, so extractors honour the mode bits below
        launcher.external_attr = (stat.S_IFREG | 0o755) << 16
        archive.writestr(launcher, '#!/bin/sh\ncd "$(dirname "$0")" || exit 1\nexec python3 run.py\n')
    temporary.replace(target)
    print(f"{target}  SHA256 {hashlib.sha256(target.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    package(parser.parse_args().output.resolve())
