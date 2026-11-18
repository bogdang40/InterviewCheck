"""Bundle the production interface and the portable FastAPI service."""
import argparse
import hashlib
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent


def package(target):
    export = ROOT / "web/out"
    if not (export / "index.html").is_file():
        raise SystemExit("Build the Next.js interface before packaging.")
    # An allowlist excludes credentials, virtual environments, caches and local records.
    files = [*sorted((ROOT / "api").glob("*.py")), ROOT / "requirements.txt", ROOT / "run.py",
             ROOT / "README.md", ROOT / "CORE.md", ROOT / "CONNECTIONS.md", ROOT / "VERIFICATION.md",
             ROOT / "evaluate.py", ROOT / "evaluation/cases.json"]
    files.extend(p for p in sorted(export.rglob("*")) if p.is_file() and not p.name.startswith("."))
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(".tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            name = "InterviewCheck/" + path.relative_to(ROOT).as_posix()
            if path.suffix == ".md":
                archive.writestr(name, path.read_text(encoding="utf-8").replace("../server/README.md", "access-server/README.md"))
            else:
                archive.write(path, name)
        server = ROOT.parent / "server"
        service = [server / name for name in ("README.md", "package.json", "package-lock.json", "tsconfig.json", ".env.example")]
        for path in service + sorted((server / "src").rglob("*.ts")):
            archive.write(path, "InterviewCheck/access-server/" + path.relative_to(server).as_posix())
        archive.writestr("InterviewCheck/Start InterviewCheck.cmd", '@echo off\r\ncd /d "%~dp0"\r\npy -3 run.py\r\nif errorlevel 1 pause\r\n')
        archive.writestr("InterviewCheck/start.sh", '#!/bin/sh\ncd "$(dirname "$0")" || exit 1\nexec python3 run.py\n')
    temporary.replace(target)
    print(f"{target}  SHA256 {hashlib.sha256(target.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    package(parser.parse_args().output.resolve())
