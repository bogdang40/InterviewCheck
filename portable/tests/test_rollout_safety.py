"""Run deploy/vm-rollout.sh and deploy/backup.sh against fake docker, az and curl, one failure path at a time."""
from pathlib import Path
import base64
import os
import subprocess
import sys
import time

import pytest

ROOT = Path(__file__).resolve().parents[2]
NEW_IMAGE = "registry.test/interviewcheck-web:new"
OLD_IMAGE = "registry.test/interviewcheck-web:old"
OLD_CADDY = "{$SITE_ADDRESS} {\n\treverse_proxy 127.0.0.1:3000\n}\n"
NEW_CADDY = OLD_CADDY.replace("reverse_proxy", "header ?Referrer-Policy \"no-referrer\"\n\treverse_proxy")

pytestmark = pytest.mark.skipif(os.name == "nt", reason="The VM scripts execute on Linux with Bash.")

FAKE_DOCKER = r"""#!/bin/bash
printf '%s|%s\n' "${IMAGE:-}" "$*" >> "$DOCKER_LOG"
case "$*" in
  *'{{.Config.Image}}'*) echo "$OLD_IMAGE" ;;
  *'{{.Image}}'*) echo sha256:oldid ;;
  *Health.Status*)
    if [ "$(cat "$STATE" 2>/dev/null)" = "$NEW_IMAGE" ] && [ "$NEW_HEALTHY" = 0 ]; then echo unhealthy; else echo healthy; fi ;;
  *"compose up"*) echo "$IMAGE" > "$STATE" ;;
  *"caddy validate"*) exit "$CADDY_VALIDATE_EXIT" ;;
esac
exit 0
"""

FAKE_BACKUP = r"""#!/bin/bash
stage=$(mktemp -d)
echo "copy taken before the new version" > "$stage/review.sqlite3"
echo "accounts before the new version" > "$stage/access.sqlite3"
mkdir -p data/.backups
tar -C "$stage" -czf "data/.backups/20261122T000000Z-pre-deploy.tar.gz" .
"""


def _tools(tmp_path: Path, extra: dict[str, str]) -> Path:
    tools = tmp_path / "bin"
    tools.mkdir()
    scripts = {"docker": FAKE_DOCKER, "systemctl": "#!/bin/bash\nexit 0\n", "chown": "#!/bin/bash\nexit 0\n",
               "sleep": "#!/bin/bash\nexit 0\n", "az": "#!/bin/bash\nexit 0\n", **extra}
    if sys.platform == "darwin":  # BSD tar matches patterns without GNU tar's --wildcards flag
        scripts["tar"] = '#!/bin/bash\nargs=()\nfor a in "$@"; do [ "$a" = --wildcards ] || args+=("$a"); done\nexec /usr/bin/tar "${args[@]}"\n'
    for name, body in scripts.items():
        (tools / name).write_text(body)
        (tools / name).chmod(0o755)
    return tools


def rollout(tmp_path, *, new_healthy=True, validate_exit=0, edge_exit=0, caddyfile=NEW_CADDY):
    work, units = tmp_path / "srv", tmp_path / "units"
    for folder in (work, units, work / "data"):
        folder.mkdir()
    (work / "app.env").write_text("fixture")
    (work / "Caddyfile").write_text(OLD_CADDY)
    (work / "data/review.sqlite3").write_text("written by the new version")
    tools = _tools(tmp_path, {"curl": f"#!/bin/bash\nexit {edge_exit}\n"})
    body = (ROOT / "deploy/vm-rollout.sh").read_text()
    script = tmp_path / "rollout.sh"
    script.write_text(body.replace("/srv/interviewcheck", str(work)).replace("/etc/systemd/system", str(units)))
    log = tmp_path / "docker.log"
    env = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}", "IMAGE": NEW_IMAGE, "ACR": "fake",
           "SITE_ADDRESS": "site.test", "BACKUP_ACCOUNT": "fake", "DOCKER_LOG": str(log),
           "STATE": str(tmp_path / "running"), "OLD_IMAGE": OLD_IMAGE, "NEW_IMAGE": NEW_IMAGE,
           "NEW_HEALTHY": "1" if new_healthy else "0", "CADDY_VALIDATE_EXIT": str(validate_exit)}
    for key, value in {"COMPOSE_B64": "services: {}", "CADDY_B64": caddyfile, "BACKUP_B64": FAKE_BACKUP}.items():
        env[key] = base64.b64encode(value.encode()).decode()
    result = subprocess.run(["bash", str(script)], env=env, text=True, capture_output=True, cwd=tmp_path)
    return result, work, log.read_text().splitlines()


def _ups(calls):
    return [line.split("|", 1)[0] for line in calls if "compose up" in line]


def _rolled_back_to_previous_image(result, work, calls):
    assert result.returncode == 1, result.stdout + result.stderr
    assert "ROLLOUT_OK" not in result.stdout
    assert any(line.endswith("|tag sha256:oldid interviewcheck-web:previous") for line in calls)
    # The running image's ID, never its tag: a rebuild of the same commit may have moved the tag.
    assert _ups(calls) == [NEW_IMAGE, "interviewcheck-web:previous"]
    assert (work / "data/review.sqlite3").read_text().strip() == "copy taken before the new version"
    kept = list((work / "data").glob(".failed-*/review.sqlite3"))
    assert [p.read_text() for p in kept] == ["written by the new version"]
    assert not (work / "deployed-image").exists()


def test_changed_caddyfile_is_validated_and_reloaded_after_the_app_is_healthy(tmp_path):
    result, work, calls = rollout(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ROLLOUT_OK" in result.stdout
    caddy = [line for line in calls if "exec -T caddy caddy" in line]
    assert [c.split("caddy caddy ")[1].split()[0] for c in caddy] == ["validate", "reload"]
    assert all("--config /etc/caddy/Caddyfile --adapter caddyfile" in c for c in caddy)
    started = next(i for i, c in enumerate(calls) if "compose up" in c)
    first_health = next(i for i, c in enumerate(calls) if "Health.Status" in c and i > started)
    assert first_health < calls.index(caddy[0])  # Caddy changes only once the new app is healthy
    assert (work / "Caddyfile").read_text() == NEW_CADDY
    assert (work / "Caddyfile.previous").read_text() == OLD_CADDY
    assert (work / "deployed-image").read_text().strip() == NEW_IMAGE


def test_unchanged_caddyfile_does_not_touch_caddy(tmp_path):
    result, work, calls = rollout(tmp_path, caddyfile=OLD_CADDY)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not [line for line in calls if "caddy caddy" in line]
    assert not (work / "Caddyfile.previous").exists()


def test_rejected_caddyfile_is_restored_and_the_app_rolls_back(tmp_path):
    result, work, calls = rollout(tmp_path, validate_exit=1)
    _rolled_back_to_previous_image(result, work, calls)
    assert (work / "Caddyfile").read_text() == OLD_CADDY
    assert "Caddy did not accept the new Caddyfile" in result.stdout


def test_failed_https_check_restores_caddyfile_and_rolls_back(tmp_path):
    result, work, calls = rollout(tmp_path, edge_exit=7)
    _rolled_back_to_previous_image(result, work, calls)
    assert (work / "Caddyfile").read_text() == OLD_CADDY
    reloads = [line for line in calls if "caddy caddy reload" in line]
    assert len(reloads) == 2  # the new file, then the previous one again


def test_unhealthy_version_rolls_back_without_reloading_caddy(tmp_path):
    result, work, calls = rollout(tmp_path, new_healthy=False)
    _rolled_back_to_previous_image(result, work, calls)
    assert not [line for line in calls if "caddy caddy" in line]
    assert (work / "Caddyfile").read_text() == OLD_CADDY


def _age(path: Path, days: float) -> None:
    stamp = time.time() - days * 86400
    os.utime(path, (stamp, stamp))


@pytest.mark.parametrize("upload_exit", [0, 1])
def test_backup_cleans_leftovers_and_fails_on_upload_failure(tmp_path, upload_exit):
    work = tmp_path / "srv"
    backups = work / "data/.backups"
    backups.mkdir(parents=True)
    for name, days in (("stale-dir", 3), ("fresh-dir", 0)):
        (backups / name).mkdir()
        _age(backups / name, days)
    (backups / "old.tar.gz").write_text("old")
    _age(backups / "old.tar.gz", 10)
    for name, days in ((".failed-old", 40), (".failed-recent", 5)):
        (work / "data" / name).mkdir()
        _age(work / "data" / name, days)
    docker = ('#!/bin/bash\ncat >/dev/null\nout="$DATA/.backups/${!#}"\nmkdir -p "$out"\n'
              'echo copy > "$out/review.sqlite3"\necho copy > "$out/access.sqlite3"\n')
    az = f'#!/bin/bash\n[[ "$*" == *"blob upload"* ]] && exit {upload_exit}\nexit 0\n'
    tools = _tools(tmp_path, {"docker": docker, "az": az})
    script = tmp_path / "backup.sh"
    script.write_text((ROOT / "deploy/backup.sh").read_text().replace("/srv/interviewcheck", str(work)))
    env = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}", "BACKUP_ACCOUNT": "fake",
           "DATA": str(work / "data")}
    result = subprocess.run(["bash", str(script), "nightly"], env=env, text=True, capture_output=True)
    assert (result.returncode == 0) == (upload_exit == 0), result.stdout + result.stderr
    archives = sorted(p.name for p in backups.glob("*.tar.gz"))
    assert len(archives) == 1 and archives[0].endswith("-nightly.tar.gz")
    assert sorted(p.name for p in backups.iterdir() if p.is_dir()) == ["fresh-dir"]
    assert sorted(p.name for p in (work / "data").glob(".failed-*")) == [".failed-recent"]
    if upload_exit:
        assert "backup upload FAILED" in result.stderr
